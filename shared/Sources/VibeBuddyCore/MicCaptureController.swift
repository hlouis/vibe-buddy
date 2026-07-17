import Foundation
// AVAudioPCMBuffer isn't annotated Sendable by AVFAudio, but we use it
// strictly within a single audio-thread callback and emit the converted
// bytes as a Data value. @preconcurrency silences the Swift 6
// concurrency diagnostics without weakening the actual safety story.
@preconcurrency import AVFoundation

// MicCaptureController is the system-microphone counterpart to the BLE
// audio path. It taps the default input node, converts whatever the
// hardware delivers (typically 44.1 / 48 kHz Float32 stereo) down to the
// 16 kHz / mono / Int16 PCM that AudioStreamer + Doubao expect, and
// hands raw PCM to AudioStreamer.ingestPCM().
//
// Lifecycle is bound to the PTT press edge: AudioSourceCoordinator
// calls start() on .start and stop() on .stop / .cancel. The engine
// is NOT held open between presses — that would keep the system mic
// indicator (iOS orange dot / macOS status-bar pill) lit the entire
// time mic mode is selected, which looks like the app is always
// listening.
//
// Cost of on-demand start: the tap delivers nothing for ~220 ms after
// start() (measured, steady state) and that speech is simply lost —
// AudioStreamer's 400 ms STT warmup does NOT cover it (that window
// only delays the Doubao socket; it cannot buffer audio the hardware
// never captured). See prime() and the coordinators for the tradeoff.
//
// Cross-platform notes:
// • macOS: AVAudioEngine works directly off the default input device;
//   no AVAudioSession exists. Permission goes through AVAudioApplication
//   (iOS 17+/macOS 14+) or the older AVCaptureDevice.requestAccess —
//   they share the same TCC service so either works.
// • iOS: AVAudioSession must be configured before the engine starts.
//   We use category .record + mode .measurement so the system doesn't
//   apply AGC/voice-processing on top of Doubao's own NS pipeline, plus
//   .bluetoothHighQualityRecording (iOS 26+) to get full-bandwidth
//   audio off AirPods instead of the legacy 8 kHz HFP profile.
@MainActor
public final class MicCaptureController {

    public enum MicError: Error, LocalizedError {
        case permissionDenied
        case engineFailed(String)
        case formatUnavailable
        case sessionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .permissionDenied:        return "Microphone permission denied."
            case .engineFailed(let m):     return "Audio engine failed: \(m)"
            case .formatUnavailable:       return "Could not negotiate 16 kHz mono Int16 PCM format."
            case .sessionFailed(let m):    return "AVAudioSession setup failed: \(m)"
            }
        }
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
    public private(set) var running = false

    public init(audio: AudioStreamer) {
        self.audio = audio
    }

    // MARK: permission

    // AVAudioApplication is the iOS 17+ / macOS 14+ recommended entry
    // point for microphone permission. Older AVCaptureDevice/.audio and
    // AVAudioSession.requestRecordPermission both still work but are
    // either deprecated (iOS) or not applicable (macOS has no
    // AVAudioSession). One API for both platforms keeps the call sites
    // simple.
    public static var permission: AppState.MicAuth {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:      return .granted
        case .denied:       return .denied
        case .undetermined: return .notDetermined
        @unknown default:   return .unknown
        }
    }

    @discardableResult
    public static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    // MARK: engine lifecycle

    // Pay CoreAudio's one-time, process-wide HAL initialization now
    // instead of on the user's first PTT press.
    //
    // Measured on macOS 15 (tools were a throwaway swiftc probe; numbers
    // are the whole construct+prepare+start sequence):
    //
    //            first cycle in a process    every later cycle
    //   block         1318 ms                    166 ms
    //   first buffer  1535 ms                    220 ms
    //
    // Unprimed, the first dictation of each app launch would swallow
    // ~1.5 s of speech and freeze the UI for ~1.3 s — long enough that a
    // quick tap gets measured past PTTSession's 350 ms click threshold
    // and turns an intended cancel into a real recording. Primed, every
    // press is the ~166/220 ms steady-state case.
    //
    // Call it when the user selects mic mode: a deliberate action where
    // a brief indicator flash (and, on iOS, a momentary duck of any
    // playing audio) is honest about what's being set up. Best-effort by
    // design — a failure here just means the first press pays the cost.
    public func prime() {
        guard !running, engine == nil else { return }
        #if os(iOS)
        guard (try? configureAudioSession()) != nil else { return }
        #endif
        let e = AVAudioEngine()
        _ = e.inputNode.inputFormat(forBus: 0)
        e.prepare()
        try? e.start()
        e.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
        NSLog("[mic] audio stack primed")
    }

    public func start() throws {
        guard !running else { return }

        #if os(iOS)
        try configureAudioSession()
        #endif

        // Every throw past this point must undo configureAudioSession().
        // It has already called setActive(true) — which ducks the user's
        // music and lights the system mic indicator — and `running`
        // stays false on the failure paths, so stop() would hit its
        // `guard running` and no-op forever. The session would then stay
        // active, with nothing capturing, until the app is force-quit:
        // exactly the always-lit indicator this whole press-edge
        // lifecycle exists to prevent.
        //
        // A defer rather than cleanup in each catch because there are
        // four throwing exits below and the first three are `guard`s
        // that are easy to add to without noticing this.
        var started = false
        defer { if !started { abandonPartialStart() } }

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
            throw MicError.engineFailed(error.localizedDescription)
        }
        running = true
        started = true
        NSLog("[mic] engine running input=%.0fHz/%dch -> 16kHz/1ch Int16",
              inFormat.sampleRate, Int(inFormat.channelCount))
    }

    // Undo a start() that threw partway. Safe to call at any point after
    // configureAudioSession(): removeTap on a bus with no tap is a no-op,
    // and the engine may not exist yet.
    private func abandonPartialStart() {
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        converter = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
        NSLog("[mic] start failed — released audio session")
    }

    public func stop() {
        guard running else { return }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        converter = nil
        running = false
        #if os(iOS)
        // Hand the audio system back to whoever was using it before
        // (e.g. background music). If we leave the session active, the
        // ducking from .record category persists.
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
        NSLog("[mic] engine stopped")
    }

    // MARK: iOS audio session

    #if os(iOS)
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()

        // Option compatibility with category .record (recording-only):
        //   • .allowBluetoothHFP — Bluetooth Hands-Free Profile, the
        //     input side of BT audio. Required for AirPods mic.
        //     (Renamed from .allowBluetooth in iOS 17. We target iOS
        //     26, so we use the new name unconditionally.)
        //   • .bluetoothHighQualityRecording — iOS 26+. Promotes the
        //     BT input from the legacy 8 kHz HFP profile to the new
        //     high-rate one when AirPods etc. negotiate it.
        //   • .allowBluetoothA2DP — *output* profile, INVALID with a
        //     record-only category. Including it here returns
        //     OSStatus -50 (paramErr) on real devices.
        //   • .defaultToSpeaker — playback-only option, also invalid.
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
        if #available(iOS 26.0, *) {
            options.insert(.bluetoothHighQualityRecording)
        }

        do {
            // .measurement disables system AGC / voice processing.
            // Doubao does its own NS / AGC server-side; double-
            // processing makes the audio mushy. .voiceChat would be
            // wrong here — that's tuned for symmetric two-way comms.
            try session.setCategory(.record, mode: .measurement, options: options)
            try session.setActive(true, options: [.notifyOthersOnDeactivation])
            NSLog("[mic] AVAudioSession configured: .record/.measurement")
        } catch {
            throw MicError.sessionFailed(error.localizedDescription)
        }
    }
    #endif

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
