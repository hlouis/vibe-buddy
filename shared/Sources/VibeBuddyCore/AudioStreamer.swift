import Foundation

// AudioStreamer sits between the BLE frame decoder and the downstream
// consumers. Phase 1 step 6 has three consumers, in order of handling:
//
//   1. front/back 200 ms trim (drops the button-press click on both ends)
//   2. streaming ASR via STTService (200 ms chunks, Doubao's sweet spot)
//   3. debug file dump under FileManager.default.temporaryDirectory
//      (lets us replay with ffplay)
//
// The tail buffer that implements the back-trim is also what prevents the
// closing click from ever reaching ASR or the file. What we discard at
// stop() is the last 200 ms the device sent us.
//
// The TextHandler is injected by the host app — macOS supplies a CGEvent
// injector, iOS supplies a UIPasteboard staging buffer. AudioStreamer
// itself is platform-neutral.
@MainActor
public final class AudioStreamer {

    // What the audio source hands us. Session-scoped: the BLE device
    // announces it in the audio/start control frame, mic mode is always
    // .pcm (AVAudioEngine has no encoder in this path).
    //
    // .opus payloads are never decoded here — we mux them into Ogg and
    // let Doubao decode. That's the whole point of encoding on-device:
    // 12x less BLE traffic, and muxing is cheap where decoding wouldn't
    // be (no libopus on the host, by design).
    public enum Codec: String, Sendable {
        case pcm
        case opus
    }

    // UI + side-effect callbacks. Everything here fires on the main actor.
    public var onSessionUpdate: ((AppState.AudioSession) -> Void)?
    public var onDumpPath: ((String) -> Void)?
    public var onSessionEnded: (() -> Void)?
    public var onASRStatus: ((String) -> Void)?
    public var onPartialText: ((String) -> Void)?
    public var onFinalText: ((String) -> Void)?
    public var onASRError: ((String) -> Void)?
    public var onPermissionRequired: (() -> Void)?

    // Collaborators. STT owns its own WebSocket; the text handler owns
    // its typing/pasteboard queue. The streamer just glues them together.
    public let stt = STTService()
    public let textHandler: any TextHandler

    // Receive-side bookkeeping (mirrors the Python dumper).
    private var file: FileHandle?
    private var dumpURL: URL?
    private var expectedSeq: UInt16 = 0
    private var gaps: Int = 0
    private var bytes: Int = 0        // bytes written to disk (post-trim)
    private var sampleRate: Int = 16000
    private var startedAt: Date = .now
    private var active: Bool = false

    // Back-end trim only. The front-end button click is already handled
    // by the firmware's 200 ms click-threshold delay — by the time audio
    // starts flowing, the press transient is long gone. Releasing, on
    // the other hand, produces a click that is still captured before we
    // see the stop event, so we still need to drop the trailing window.
    //
    // This is BLE-specific: the click only exists because the device has
    // a physical button next to its mic. Mic-mode (system microphone +
    // global hotkey) has no such transient — and trimming 200 ms there
    // would clip the user's last syllable. tailTrimMs is therefore set
    // per-session via handlePTT() / startSession(tailTrimMs:).
    // `nonisolated` so it can be referenced from default-argument
    // expressions on @MainActor methods without tripping Swift 6
    // strict-concurrency diagnostics.
    public nonisolated static let defaultTailTrimMs: Int = 200
    private var tailTrimMs: Int = AudioStreamer.defaultTailTrimMs
    private var trimBytes: Int { tailTrimMs * sampleRate * 2 / 1000 }
    private var tailBuffer = Data()

    // ASR requires 100-200 ms chunks; 200 ms is optimal for bigmodel_async.
    // @16 kHz/16 bit/mono that's 6400 bytes per chunk.
    private var asrChunkBytes: Int { 200 * sampleRate * 2 / 1000 }
    private var asrAccumulator = Data()

    // MARK: Opus session state
    //
    // The PCM path trims a trailing byte window; Opus can only trim whole
    // packets, so the tail is a packet queue instead of a byte buffer.
    // Everything downstream of the trim converges again: Ogg bytes land
    // in the same asrAccumulator the PCM path uses, so the warmup gate
    // and flush-on-arm logic are shared verbatim.
    private var codec: Codec = .pcm
    private var oggMuxer = OggOpusMuxer(sampleRate: 16000)
    private var opusTail: [Data] = []

    // Frame size the firmware encodes at (AUDIO_FRAME_MS in recorder.cpp).
    // Opus permits 2.5–60 ms; we use the max because fewer, larger BLE
    // notifies beat more, smaller ones on this link.
    private static let opusFrameMs: Int = 60
    private var opusSamplesPerPacket: Int { Self.opusFrameMs * sampleRate / 1000 }

    // How many whole packets the trailing trim window covers. Rounded up
    // so we never leave part of the release click in: at 60 ms packets a
    // 200 ms window is 4 packets (240 ms). Coarser than the PCM path's
    // byte-exact trim, which is inherent to trimming a compressed stream.
    private var opusTrimPackets: Int {
        tailTrimMs <= 0 ? 0 : (tailTrimMs + Self.opusFrameMs - 1) / Self.opusFrameMs
    }

    // STT warm-up gate. The firmware starts recording speculatively on
    // BtnA press and sends audio/cancel if it turns out to be a click
    // (< 350 ms). We hold off opening the Doubao WebSocket for 400 ms of
    // wall-clock time after audio/start so clicks cost zero network,
    // not even a handshake round-trip. Any audio that arrives during the
    // warmup sits in asrAccumulator; we flush it in one shot when armed.
    private static let sttWarmupMs: Int = 400
    private var sttArmed: Bool = false
    private var sttWarmupTask: Task<Void, Never>?

    public init(textHandler: any TextHandler) {
        self.textHandler = textHandler
        stt.onPartial = { [weak self] text in
            guard let self else { return }
            self.onPartialText?(text)
            self.textHandler.update(to: text)
        }
        stt.onFinal = { [weak self] text in
            guard let self else { return }
            self.onFinalText?(text)
            self.textHandler.update(to: text)
        }
        stt.onStatus = { [weak self] status in
            self?.onASRStatus?(AudioStreamer.describe(status))
        }
        stt.onError = { [weak self] msg in
            self?.onASRError?(msg)
        }
        textHandler.onPermissionRequired = { [weak self] in
            self?.onPermissionRequired?()
        }
    }

    // MARK: BLE control-frame hooks

    public func handleControl(_ line: String) {
        if line.contains("\"event\":\"start\"") {
            let sr = extractInt(from: line, key: "sample_rate") ?? 16000
            // Absent "codec" means PCM: that's what every firmware before
            // the Opus change emits, and an old stick must keep working
            // against a new app.
            let codec = extractString(from: line, key: "codec")
                .flatMap { Codec(rawValue: $0) } ?? .pcm
            handlePTT(.start(sampleRate: sr),
                      tailTrimMs: AudioStreamer.defaultTailTrimMs,
                      codec: codec)
        } else if line.contains("\"event\":\"stop\"") {
            handlePTT(.stop)
        } else if line.contains("\"event\":\"cancel\"") {
            handlePTT(.cancel)
        }
    }

    // MARK: source-agnostic PTT entry point
    //
    // Both the BLE control-frame path and the macOS hotkey path funnel
    // through here. The tailTrimMs argument is what makes mic mode work
    // without clipping speech: BLE passes 200, mic passes 0.

    public func handlePTT(_ event: PTTEvent,
                          tailTrimMs: Int = AudioStreamer.defaultTailTrimMs,
                          codec: Codec = .pcm) {
        switch event {
        case .start(let sr):
            self.sampleRate = sr
            self.tailTrimMs = max(0, tailTrimMs)
            self.codec = codec
            startSession()
        case .stop:
            endSession()
        case .cancel:
            cancelSession()
        }
    }

    // MARK: source-agnostic PCM ingest
    //
    // Mic mode has no notion of sequence numbers (AVAudioEngine just
    // hands us a stream of buffers). Synthesizing matching seqs means
    // the gap-detection branch in onAudioFrame is a permanent no-op for
    // mic input — exactly what we want.

    public func ingestPCM(_ pcm: Data) {
        onAudioFrame(seq: expectedSeq, payload: pcm)
    }

    // MARK: BLE audio-frame hook

    // `payload` is raw PCM or one Opus packet depending on the session's
    // codec. Mic mode only ever reaches here via ingestPCM.
    public func onAudioFrame(seq: UInt16, payload: Data) {
        guard active, file != nil else { return }

        let gap = detectGap(seq: seq)
        expectedSeq = seq &+ 1

        switch codec {
        case .pcm:  ingestPCMFrame(payload, gap: gap)
        case .opus: ingestOpusPacket(payload, gap: gap)
        }
        emit()
    }

    // Returns how many frames were lost before this one. Bounded to
    // reject the garbage a desync would otherwise turn into a huge
    // allocation.
    private func detectGap(seq: UInt16) -> Int {
        guard seq != expectedSeq else { return 0 }
        let gap = Int(seq &- expectedSeq)
        guard gap > 0 && gap < 1000 else { return 0 }
        gaps += gap
        NSLog("[audio] gap: expected=%u got=%u (+%d)", expectedSeq, seq, gap)
        return gap
    }

    private func ingestPCMFrame(_ pcm: Data, gap: Int) {
        var incoming = Data()
        if gap > 0 { incoming.append(Data(count: pcm.count * gap)) }  // pad with silence
        incoming.append(pcm)

        // Back trim: only flush bytes older than the 200 ms trailing window.
        tailBuffer.append(incoming)
        let excess = tailBuffer.count - trimBytes
        guard excess > 0 else { return }
        let flushed = tailBuffer.prefix(excess)
        tailBuffer.removeFirst(excess)
        bytes += excess
        emitToSinks(Data(flushed))
    }

    // Opus can't be gap-padded: there's no "silent packet" we can
    // synthesize without an encoder, and splicing a wrong-length packet
    // in would corrupt the stream. We count the gap and move on — the
    // decoder sees a slightly time-compressed stream, which for ASR
    // beats a corrupt one. Gaps are rare enough on a 2M link that this
    // has never been the interesting failure mode.
    private func ingestOpusPacket(_ packet: Data, gap: Int) {
        guard !packet.isEmpty else { return }
        opusTail.append(packet)
        while opusTail.count > opusTrimPackets {
            let p = opusTail.removeFirst()
            bytes += p.count
            emitToSinks(oggMuxer.append(opusPacket: p))
        }
    }

    // Shared tail of both codec paths: dump file + ASR accumulator, with
    // the same warmup gate. Whatever arrives here is already trimmed and
    // in whatever wire format STT expects for this session.
    private func emitToSinks(_ data: Data) {
        guard !data.isEmpty else { return }
        file?.write(data)
        asrAccumulator.append(data)
        // When not armed yet, just let asrAccumulator grow. It'll get
        // drained in one shot when the warmup timer fires.
        if sttArmed { drainASRChunks() }
    }

    public func cancelSession() {
        guard active else { return }
        sttWarmupTask?.cancel()
        sttWarmupTask = nil
        if sttArmed {
            NSLog("[audio] cancelled (STT was armed, tearing down)")
            stt.cancel()
            textHandler.rollback()
        } else {
            NSLog("[audio] cancelled during warmup — zero network cost")
        }
        tailBuffer.removeAll()
        opusTail.removeAll()
        asrAccumulator.removeAll()
        closeFile()
        active = false
        sttArmed = false
        emit()
        emitDone()
    }

    // MARK: private

    private func startSession() {
        closeFile()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("VibeBuddy")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The Opus dump is a real Ogg file — playable by anything, no
        // ffplay -f s16le incantation needed.
        let url = dir.appendingPathComponent(codec == .opus ? "out.ogg" : "out.pcm")
        FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil)
        self.file = try? FileHandle(forWritingTo: url)
        self.dumpURL = url

        expectedSeq = 0
        gaps = 0
        bytes = 0
        tailBuffer.removeAll(keepingCapacity: true)
        asrAccumulator.removeAll(keepingCapacity: true)
        opusTail.removeAll(keepingCapacity: true)
        oggMuxer = OggOpusMuxer(sampleRate: sampleRate,
                                channels: 1,
                                samplesPerPacket: opusSamplesPerPacket)
        startedAt = .now
        active = true
        sttArmed = false

        textHandler.reset()
        // Arm STT after warmup — clicks that cancel within this window
        // cost zero network. If we cross the threshold while still
        // recording, we flush whatever's buffered into Doubao in one
        // shot and switch to streaming mode.
        sttWarmupTask?.cancel()
        sttWarmupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(AudioStreamer.sttWarmupMs) * 1_000_000)
            await MainActor.run { self?.armSTT() }
        }

        NSLog("[audio] session -> %@ (codec=%@ rate=%d tailTrim=%dms warmup=%dms)",
              url.path, codec.rawValue, sampleRate, tailTrimMs,
              AudioStreamer.sttWarmupMs)
        onDumpPath?(url.path)
        emit()
    }

    private func endSession() {
        guard active else { return }
        sttWarmupTask?.cancel()
        sttWarmupTask = nil
        // Whatever's still held back by the trim window is the release
        // click — dropping it is the entire point.
        let droppedTail = codec == .opus ? opusTail.count : tailBuffer.count
        tailBuffer.removeAll()
        opusTail.removeAll()
        // Close the Ogg stream so the dump is a valid file and the server
        // sees a proper EOS. Must happen before the final flush below.
        if codec == .opus {
            let eos = oggMuxer.finish()
            file?.write(eos)
            asrAccumulator.append(eos)
        }
        closeFile()

        if sttArmed {
            // Flush whatever's left in the ASR accumulator, even if shorter
            // than one chunk — the server accepts sub-200 ms chunks too.
            if !asrAccumulator.isEmpty {
                stt.pushAudio(asrAccumulator)
                asrAccumulator.removeAll()
            }
            stt.endSession()
            NSLog("[audio] session done: bytes=%d gaps=%d trim_tail=%d dur=%.2fs",
                  bytes, gaps, droppedTail, Date.now.timeIntervalSince(startedAt))
        } else {
            // Hold was longer than a click but shorter than warmup — no
            // STT was ever armed, so nothing to finalize. Silent drop.
            NSLog("[audio] session ended before STT armed (%d bytes pre-trim); dropped",
                  asrAccumulator.count)
            asrAccumulator.removeAll()
        }
        active = false
        sttArmed = false
        emit()
        emitDone()
    }

    @MainActor
    private func armSTT() {
        guard active, !sttArmed else { return }
        sttArmed = true
        NSLog("[audio] STT warmup elapsed — arming session, flushing %d pre-buffered bytes",
              asrAccumulator.count)
        stt.startSession(sampleRate: sampleRate, codec: codec)
        drainASRChunks()
    }

    // PCM is re-chunked to Doubao's 200 ms sweet spot. Ogg is not: its
    // pages are already framed, and re-cutting them at arbitrary byte
    // offsets would just hand the server torn pages. Push what we have.
    private func drainASRChunks() {
        switch codec {
        case .opus:
            guard !asrAccumulator.isEmpty else { return }
            stt.pushAudio(asrAccumulator)
            asrAccumulator.removeAll(keepingCapacity: true)
        case .pcm:
            while asrAccumulator.count >= asrChunkBytes {
                let chunk = Data(asrAccumulator.prefix(asrChunkBytes))
                asrAccumulator.removeFirst(asrChunkBytes)
                stt.pushAudio(chunk)
            }
        }
    }

    private func closeFile() {
        try? file?.close()
        file = nil
    }

    private func emit() {
        onSessionUpdate?(AppState.AudioSession(
            active: active,
            bytes: bytes,
            gaps: gaps,
            sampleRate: sampleRate,
            startedAt: startedAt,
            // Stamped here rather than computed by the UI: the last emit
            // of a session is the one that freezes the final duration.
            durationSec: Date.now.timeIntervalSince(startedAt),
            codec: codec
        ))
    }

    private func emitDone() { onSessionEnded?() }

    private func extractString(from line: String, key: String) -> String? {
        guard let range = line.range(of: "\"\(key)\":\"") else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private func extractInt(from line: String, key: String) -> Int? {
        guard let range = line.range(of: "\"\(key)\":") else { return nil }
        let rest = line[range.upperBound...]
        let digits = rest.drop(while: { !$0.isNumber }).prefix { $0.isNumber }
        return Int(digits)
    }

    private static func describe(_ s: STTService.Status) -> String {
        switch s {
        case .idle:              return "idle"
        case .connecting:        return "connecting"
        case .streaming:         return "streaming"
        case .closing:           return "closing"
        case .failed(let msg):   return "failed: \(msg)"
        }
    }
}
