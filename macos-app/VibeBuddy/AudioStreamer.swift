import Foundation

// AudioStreamer sits between the BLE frame decoder and the downstream
// consumers. Phase 1 step 6 has three consumers, in order of handling:
//
//   1. front/back 200 ms trim (drops the button-press click on both ends)
//   2. streaming ASR via STTService (200 ms chunks, Doubao's sweet spot)
//   3. debug file dump at /tmp/VibeBuddy/out.pcm (lets us replay with ffplay)
//
// The tail buffer that implements the back-trim is also what prevents the
// closing click from ever reaching ASR or the file. What we discard at
// stop() is the last 200 ms the device sent us.
@MainActor
final class AudioStreamer {

    // UI + side-effect callbacks. Everything here fires on the main actor.
    var onSessionUpdate: ((AppState.AudioSession) -> Void)?
    var onDumpPath: ((String) -> Void)?
    var onSessionEnded: (() -> Void)?
    var onASRStatus: ((String) -> Void)?
    var onPartialText: ((String) -> Void)?
    var onFinalText: ((String) -> Void)?
    var onASRError: ((String) -> Void)?
    var onPermissionRequired: (() -> Void)?

    // Collaborators. STT owns its own WebSocket; injector owns its typing
    // queue. The streamer just glues them together.
    let stt = STTService()
    let injector = TextInjector()

    // Receive-side bookkeeping (mirrors the Python dumper).
    private var file: FileHandle?
    private var dumpURL: URL?
    private var expectedSeq: UInt16 = 0
    private var gaps: Int = 0
    private var bytes: Int = 0        // bytes written to disk (post-trim)
    private var sampleRate: Int = 16000
    private var startedAt: Date = .now
    private var active: Bool = false

    // Trim configuration — 200 ms on each end. Re-computed on start()
    // because the firmware may eventually fall back to 8 kHz.
    private static let trimMs: Int = 200
    private var trimBytes: Int { AudioStreamer.trimMs * sampleRate * 2 / 1000 }
    private var frontSkipRemaining: Int = 0
    private var tailBuffer = Data()

    // ASR requires 100-200 ms chunks; 200 ms is optimal for bigmodel_async.
    // @16 kHz/16 bit/mono that's 6400 bytes per chunk.
    private var asrChunkBytes: Int { 200 * sampleRate * 2 / 1000 }
    private var asrAccumulator = Data()

    init() {
        stt.onPartial = { [weak self] text in
            guard let self else { return }
            self.onPartialText?(text)
            self.injector.update(to: text)
        }
        stt.onFinal = { [weak self] text in
            guard let self else { return }
            self.onFinalText?(text)
            self.injector.update(to: text)
        }
        stt.onStatus = { [weak self] status in
            self?.onASRStatus?(AudioStreamer.describe(status))
        }
        stt.onError = { [weak self] msg in
            self?.onASRError?(msg)
        }
        injector.onPermissionRequired = { [weak self] in
            self?.onPermissionRequired?()
        }
    }

    // MARK: BLE control-frame hooks

    func handleControl(_ line: String) {
        if line.contains("\"event\":\"start\"") {
            sampleRate = extractInt(from: line, key: "sample_rate") ?? 16000
            startSession()
        } else if line.contains("\"event\":\"stop\"") {
            endSession()
        } else if line.contains("\"event\":\"cancel\"") {
            cancelSession()
        }
    }

    // MARK: BLE audio-frame hook

    func onAudioFrame(seq: UInt16, pcm: Data) {
        guard active, file != nil else { return }

        var incoming = Data()
        if seq != expectedSeq {
            let gap = Int(seq &- expectedSeq)
            if gap > 0 && gap < 1000 {
                incoming.append(Data(count: pcm.count * gap))
                gaps += gap
                NSLog("[audio] gap: expected=%u got=%u (+%d)", expectedSeq, seq, gap)
            }
        }
        incoming.append(pcm)
        expectedSeq = seq &+ 1

        // Front trim
        if frontSkipRemaining > 0 {
            let skip = min(frontSkipRemaining, incoming.count)
            incoming.removeFirst(skip)
            frontSkipRemaining -= skip
            if incoming.isEmpty { emit(); return }
        }

        // Back trim: only flush bytes older than the 200 ms trailing window.
        tailBuffer.append(incoming)
        let excess = tailBuffer.count - trimBytes
        if excess > 0 {
            let flushed = tailBuffer.prefix(excess)
            tailBuffer.removeFirst(excess)
            bytes += excess
            file?.write(flushed)
            asrAccumulator.append(flushed)
            drainASRChunks()
        }
        emit()
    }

    func cancelSession() {
        guard active else { return }
        NSLog("[audio] cancelled")
        stt.cancel()
        Task { @MainActor in self.injector.rollback() }
        tailBuffer.removeAll()
        asrAccumulator.removeAll()
        closeFile()
        active = false
        emit()
        emitDone()
    }

    // MARK: private

    private func startSession() {
        closeFile()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("VibeBuddy")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("out.pcm")
        FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil)
        self.file = try? FileHandle(forWritingTo: url)
        self.dumpURL = url

        expectedSeq = 0
        gaps = 0
        bytes = 0
        frontSkipRemaining = trimBytes
        tailBuffer.removeAll(keepingCapacity: true)
        asrAccumulator.removeAll(keepingCapacity: true)
        startedAt = .now
        active = true

        injector.reset()
        stt.startSession(sampleRate: sampleRate)

        NSLog("[audio] session -> %@ (rate=%d trim=%dms asrChunk=%dB)",
              url.path, sampleRate, AudioStreamer.trimMs, asrChunkBytes)
        onDumpPath?(url.path)
        emit()
    }

    private func endSession() {
        guard active else { return }
        // Flush whatever's left in the ASR accumulator, even if shorter
        // than one chunk — the server accepts sub-200 ms chunks too.
        if !asrAccumulator.isEmpty {
            stt.pushAudio(asrAccumulator)
            asrAccumulator.removeAll()
        }
        // Tail buffer = the last 200 ms; intentionally NOT flushed. This
        // is also the click-protection we promised users.
        let droppedTail = tailBuffer.count
        tailBuffer.removeAll()
        closeFile()
        stt.endSession()
        active = false
        NSLog("[audio] session done: bytes=%d gaps=%d trim_tail=%d dur=%.2fs",
              bytes, gaps, droppedTail, Date.now.timeIntervalSince(startedAt))
        emit()
        emitDone()
    }

    private func drainASRChunks() {
        while asrAccumulator.count >= asrChunkBytes {
            let chunk = Data(asrAccumulator.prefix(asrChunkBytes))
            asrAccumulator.removeFirst(asrChunkBytes)
            stt.pushAudio(chunk)
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
            startedAt: startedAt
        ))
    }

    private func emitDone() { onSessionEnded?() }

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
