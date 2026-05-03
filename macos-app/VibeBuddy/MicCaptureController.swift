import Foundation
// AVAudioPCMBuffer isn't annotated Sendable by AVFAudio, but we use it
// strictly within a single audio-thread callback and emit the converted
// bytes as a Data value. @preconcurrency silences the Swift 6
// concurrency diagnostics without weakening the actual safety story.
@preconcurrency import AVFoundation
import VibeBuddyCore

// MicCaptureController is the system-microphone counterpart to the BLE
// audio path. It taps the default input node, converts whatever the
// hardware delivers (typically 44.1 / 48 kHz Float32 stereo) down to the
// 16 kHz / mono / Int16 PCM that AudioStreamer + Doubao expect, and
// hands raw PCM to AudioStreamer.ingestPCM().
//
// Lifecycle is decoupled from sessions: the engine runs continuously
// while mic mode is active, and the gating between "buffering vs
// silently dropping" is done by AudioStreamer.active (toggled by PTT
// start/stop/cancel). That avoids the 100–300 ms warm-up latency we'd
// pay if we started the engine on every PTT press.
@MainActor
final class MicCaptureController {

    enum MicError: Error {
        case permissionDenied
        case engineFailed(String)
        case formatUnavailable
    }

    // The engine is built lazily on each start() rather than once at
    // init. Reason: AVAudioEngine.inputNode binds to the underlying
    // CoreAudio device at construction time. If we built the engine
    // before the user granted mic permission (we do — the coordinator
    // is created at app launch, the grant comes later), the inputNode
    // is bound to a no-permission stub and just streams silence even
    // after the grant arrives. The user's only recourse used to be
    // restarting the app. Now we rebuild on every start() so the first
    // post-grant start always picks up a fresh, properly-bound input.
    private var engine: AVAudioEngine?
    private let targetSampleRate: Double = 16000
    private var converter: AVAudioConverter?
    private weak var audio: AudioStreamer?
    private(set) var running = false

    init(audio: AudioStreamer) {
        self.audio = audio
    }

    // MARK: permission

    static var permission: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { c in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                c.resume(returning: granted)
            }
        }
    }

    // MARK: engine lifecycle

    func start() throws {
        guard !running else { return }
        // Fresh engine every time — see the comment on `engine` for
        // why this matters (post-grant input-node rebinding).
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw MicError.formatUnavailable
        }
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: targetSampleRate,
                                            channels: 1,
                                            interleaved: true) else {
            throw MicError.formatUnavailable
        }
        guard let conv = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw MicError.formatUnavailable
        }
        self.converter = conv

        // 1024 frames at the input rate is ~21 ms @48kHz — small enough
        // for low PTT latency, large enough to amortize converter setup.
        // The tap fires on the audio thread; we do conversion there and
        // hop back to the main actor only to deliver the converted PCM.
        let tapBufSize: AVAudioFrameCount = 1024
        input.installTap(onBus: 0, bufferSize: tapBufSize, format: inFormat) { [weak self, conv, outFormat] buf, _ in
            guard let data = MicCaptureController.convert(buf: buf, conv: conv, outFormat: outFormat) else { return }
            Task { @MainActor [weak self] in
                self?.audio?.ingestPCM(data)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.engine = nil
            self.converter = nil
            throw MicError.engineFailed(error.localizedDescription)
        }
        running = true
        NSLog("[mic] engine running input=%.0fHz/%dch -> 16kHz/1ch Int16",
              inFormat.sampleRate, Int(inFormat.channelCount))
    }

    func stop() {
        guard running else { return }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        converter = nil
        running = false
        NSLog("[mic] engine stopped")
    }

    // MARK: conversion (audio thread)
    //
    // Static so the tap closure doesn't need to touch `self` from the
    // audio thread — `self` is @MainActor-isolated and that would
    // require a hop on every buffer. The converter is captured by value
    // (it's a class, so the closure holds a reference). AVAudioConverter
    // is documented as not thread-safe across concurrent calls, but
    // single-threaded use from one tap thread is fine.
    nonisolated static func convert(buf: AVAudioPCMBuffer,
                                    conv: AVAudioConverter,
                                    outFormat: AVAudioFormat) -> Data? {
        let inRate = buf.format.sampleRate
        let outRate = outFormat.sampleRate
        let ratio = outRate / max(inRate, 1)
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio + 1024)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return nil }

        var fed = false
        var convErr: NSError?
        let status = conv.convert(to: outBuf, error: &convErr) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buf
        }
        if status == .error || outBuf.frameLength == 0 {
            if let convErr { NSLog("[mic] converter error: %@", convErr.localizedDescription) }
            return nil
        }
        guard let int16 = outBuf.int16ChannelData else { return nil }
        let byteCount = Int(outBuf.frameLength) * 2
        return Data(bytes: int16[0], count: byteCount)
    }
}
