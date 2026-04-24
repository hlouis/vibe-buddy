import Foundation

// Step 5 AudioStreamer: mirrors tools/ble_audio_dump.py exactly. Receives
// audio/start and audio/stop control frames from the JSON stream and
// binary PCM frames via onAudioFrame. Dumps to disk for bring-up so we
// can verify byte-for-byte parity with the Python tool.
//
// Step 6 will keep the same control-frame interface but swap the file
// sink for a streaming ASR WebSocket and a TextInjector consumer.
@MainActor
final class AudioStreamer {
    var onSessionUpdate: ((AppState.AudioSession) -> Void)?
    var onDumpPath: ((String) -> Void)?
    var onSessionEnded: (() -> Void)?

    private var file: FileHandle?
    private var dumpURL: URL?
    private var expectedSeq: UInt16 = 0
    private var gaps: Int = 0
    private var bytes: Int = 0
    private var sampleRate: Int = 16000
    private var startedAt: Date = .now
    private var active: Bool = false

    // Trim 200 ms from both ends to drop button-press click + ES8311
    // settling noise. Front is a simple byte-skip counter; back is a
    // rolling tail buffer that holds the most recent 200 ms of audio;
    // on stop we just discard it without flushing.
    private static let trimMs: Int = 200
    private var trimBytes: Int { AudioStreamer.trimMs * sampleRate * 2 / 1000 }
    private var frontSkipRemaining: Int = 0
    private var tailBuffer = Data()

    func handleControl(_ line: String) {
        if line.contains("\"event\":\"start\"") {
            if let r = extractInt(from: line, key: "sample_rate") {
                sampleRate = r
            } else {
                sampleRate = 16000
            }
            startSession()
        } else if line.contains("\"event\":\"stop\"") {
            endSession()
        } else if line.contains("\"event\":\"cancel\"") {
            cancelSession()
        }
    }

    func onAudioFrame(seq: UInt16, pcm: Data) {
        guard active, file != nil else { return }

        // Build the logical-samples-this-frame blob first (silence pad on
        // gap, then the frame itself). Trim logic is pure byte-level
        // after this so gap handling and normal frames share one path.
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

        // Front trim: eat up to trimBytes from the head of the stream.
        if frontSkipRemaining > 0 {
            let skip = min(frontSkipRemaining, incoming.count)
            incoming.removeFirst(skip)
            frontSkipRemaining -= skip
            if incoming.isEmpty { return }
        }

        // Back trim: only flush bytes older than the trailing 200 ms
        // window. Whatever sits in tailBuffer at stop() gets discarded.
        tailBuffer.append(incoming)
        let excess = tailBuffer.count - trimBytes
        if excess > 0 {
            let toWrite = tailBuffer.prefix(excess)
            file?.write(toWrite)
            tailBuffer.removeFirst(excess)
            bytes += excess
        }
        emit()
    }

    func cancelSession() {
        guard active else { return }
        NSLog("[audio] cancelled at bytes=%d", bytes)
        closeFile()
        active = false
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
        startedAt = .now
        active = true
        NSLog("[audio] session -> %@ (trim %dms front/back)", url.path, AudioStreamer.trimMs)
        onDumpPath?(url.path)
        emit()
    }

    private func endSession() {
        guard active else { return }
        let droppedTail = tailBuffer.count
        tailBuffer.removeAll()
        closeFile()
        active = false
        NSLog("[audio] session done: bytes=%d gaps=%d trim_tail=%d dur=%.2fs",
              bytes, gaps, droppedTail, Date.now.timeIntervalSince(startedAt))
        if let path = dumpURL?.path {
            NSLog("[audio] ffplay -autoexit -f s16le -ar %d -ac 1 %@", sampleRate, path)
        }
        emit()
        emitDone()
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

    private func emitDone() {
        onSessionEnded?()
    }

    private func extractInt(from line: String, key: String) -> Int? {
        guard let range = line.range(of: "\"\(key)\":") else { return nil }
        let rest = line[range.upperBound...]
        let digits = rest.drop(while: { !$0.isNumber }).prefix { $0.isNumber }
        return Int(digits)
    }
}
