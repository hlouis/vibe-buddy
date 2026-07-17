import XCTest
@testable import VibeBuddyCore

// AudioStreamer is the source-agnostic glue between PTT events / PCM
// frames and (eventually) the Doubao streaming ASR client. Three
// concerns these tests pin down:
//
//   1. Session lifecycle: handlePTT(.start/.stop/.cancel) toggles the
//      internal `active` flag and emits AudioSession updates accordingly.
//      ingestPCM and onAudioFrame both honour the flag — late tap
//      buffers (post-cancel, post-stop) are silently dropped. This is
//      the invariant that makes the on-demand mic lifecycle safe.
//
//   2. STT warmup gate: when a session ends/cancels inside the 400 ms
//      warmup window, the STT client is never armed and the TextHandler
//      receives no rollback. Long sessions are intentionally NOT
//      exercised here — they would arm STT and open a real WebSocket
//      to Doubao, which is a unit-test antipattern.
//
//   3. Tail trim: tailTrimMs=0 (mic mode) flushes every byte; the
//      default 200 ms @ 16 kHz buffers 6400 bytes before flushing — the
//      exact invariant that lets BLE mode drop the closing-click tail.
//
// FakeTextHandler is a recording stand-in for the platform handlers
// (CGEvent injector on macOS, UIPasteboard staging buffer on iOS).
@MainActor
final class AudioStreamerTests: XCTestCase {

    private final class FakeTextHandler: TextHandler {
        var onPermissionRequired: (() -> Void)?
        private(set) var updates: [String] = []
        private(set) var resetCount = 0
        private(set) var rollbackCount = 0
        private(set) var sendEnterCount = 0
        private(set) var sendBackspaceCharCount = 0
        private(set) var clearAllCount = 0
        var permissionAnswer: Bool = true

        func checkPermission() -> Bool { permissionAnswer }
        func update(to newText: String) { updates.append(newText) }
        func reset() { resetCount += 1 }
        func sendEnter() { sendEnterCount += 1 }
        func sendBackspaceChar() { sendBackspaceCharCount += 1 }
        func clearAll() { clearAllCount += 1 }
        func rollback() { rollbackCount += 1 }
    }

    private var streamer: AudioStreamer!
    private var handler: FakeTextHandler!
    private var sessionUpdates: [AppState.AudioSession] = []
    private var sessionEndedCount = 0
    private var dumpPaths: [String] = []

    override func setUp() {
        super.setUp()
        handler = FakeTextHandler()
        streamer = AudioStreamer(textHandler: handler)
        sessionUpdates = []
        sessionEndedCount = 0
        dumpPaths = []
        streamer.onSessionUpdate = { [weak self] in self?.sessionUpdates.append($0) }
        streamer.onSessionEnded   = { [weak self] in self?.sessionEndedCount += 1 }
        streamer.onDumpPath       = { [weak self] in self?.dumpPaths.append($0) }
    }

    override func tearDown() {
        // Force-cancel any in-flight session so the warmup Task doesn't
        // leak across tests and accidentally arm STT in a later test.
        streamer.cancelSession()
        streamer = nil
        handler = nil
        super.tearDown()
    }

    // MARK: lifecycle — start / stop / cancel

    func testStartActivatesSessionAndResetsTextHandler() {
        streamer.handlePTT(.start(sampleRate: 16000))
        XCTAssertEqual(handler.resetCount, 1, "TextHandler.reset must fire on session start")
        XCTAssertEqual(sessionUpdates.last?.active, true)
        XCTAssertEqual(sessionUpdates.last?.sampleRate, 16000)
        XCTAssertNotNil(dumpPaths.first, "dump path callback must fire on start")
        XCTAssertTrue(dumpPaths.first?.hasSuffix("out.pcm") == true)
    }

    func testStopBeforeWarmupSilentlyEndsSession() {
        streamer.handlePTT(.start(sampleRate: 16000), tailTrimMs: 0)
        streamer.handlePTT(.stop)

        XCTAssertEqual(sessionUpdates.last?.active, false)
        XCTAssertEqual(sessionEndedCount, 1)
        XCTAssertEqual(handler.updates, [],
                       "STT never armed → no transcript ever reached TextHandler")
        XCTAssertEqual(handler.rollbackCount, 0,
                       "rollback must NOT fire on a clean stop")
    }

    func testCancelBeforeWarmupTearsDownWithoutRollback() {
        streamer.handlePTT(.start(sampleRate: 16000), tailTrimMs: 0)
        streamer.handlePTT(.cancel)

        XCTAssertEqual(sessionUpdates.last?.active, false)
        XCTAssertEqual(sessionEndedCount, 1)
        XCTAssertEqual(handler.rollbackCount, 0,
                       "rollback is for armed sessions only — short presses must be silent")
    }

    func testStopWithoutStartIsNoop() {
        streamer.handlePTT(.stop)
        XCTAssertEqual(sessionEndedCount, 0)
        XCTAssertEqual(sessionUpdates.count, 0)
    }

    func testCancelWithoutStartIsNoop() {
        streamer.handlePTT(.cancel)
        XCTAssertEqual(sessionEndedCount, 0)
        XCTAssertEqual(sessionUpdates.count, 0)
    }

    func testStartAfterStopBeginsFreshSession() {
        streamer.handlePTT(.start(sampleRate: 16000), tailTrimMs: 0)
        streamer.handlePTT(.stop)
        let firstSessionEnded = sessionEndedCount

        streamer.handlePTT(.start(sampleRate: 16000), tailTrimMs: 0)
        XCTAssertEqual(handler.resetCount, 2, "reset must fire on every fresh start")
        XCTAssertEqual(sessionUpdates.last?.active, true)
        XCTAssertEqual(sessionEndedCount, firstSessionEnded,
                       "starting a new session must not emit session-ended")
    }

    // MARK: ingest gating — the safety net for on-demand mic
    //
    // When AudioSourceCoordinator releases the engine on PTT release,
    // already-dispatched tap callbacks may still hit ingestPCM. Those
    // must drop on the floor.

    func testIngestPCMDroppedWhenNoSession() {
        streamer.ingestPCM(Data(repeating: 0xAB, count: 1000))
        XCTAssertEqual(sessionUpdates.count, 0,
                       "PCM outside any session must not produce side effects")
    }

    func testIngestPCMDroppedAfterCancel() {
        streamer.handlePTT(.start(sampleRate: 16000), tailTrimMs: 0)
        streamer.handlePTT(.cancel)
        let updatesBefore = sessionUpdates.count

        streamer.ingestPCM(Data(repeating: 0xAB, count: 1000))
        XCTAssertEqual(sessionUpdates.count, updatesBefore,
                       "late tap buffers after cancel must be dropped")
    }

    func testIngestPCMDroppedAfterStop() {
        streamer.handlePTT(.start(sampleRate: 16000), tailTrimMs: 0)
        streamer.handlePTT(.stop)
        let updatesBefore = sessionUpdates.count

        streamer.ingestPCM(Data(repeating: 0xAB, count: 1000))
        XCTAssertEqual(sessionUpdates.count, updatesBefore,
                       "late tap buffers after stop must be dropped")
    }

    // MARK: tail trim

    func testTailTrimZeroFlushesAllBytesImmediately() {
        streamer.handlePTT(.start(sampleRate: 16000), tailTrimMs: 0)
        streamer.ingestPCM(Data(repeating: 0xAB, count: 500))
        XCTAssertEqual(sessionUpdates.last?.bytes, 500,
                       "tailTrimMs=0 (mic mode) must flush every byte through")
    }

    func testTailTrimDefaultHoldsTrailingWindow() {
        // 200 ms @ 16 kHz / 16-bit / mono = 6400 bytes. Anything below
        // that stays in the tail buffer and never reaches disk / ASR.
        streamer.handlePTT(.start(sampleRate: 16000))  // default tailTrimMs = 200
        streamer.ingestPCM(Data(repeating: 0xAB, count: 1000))
        XCTAssertEqual(sessionUpdates.last?.bytes, 0,
                       "BLE-mode default trim must buffer up to 6400 bytes before flushing")
    }

    func testTailTrimFlushesOnlyExcess() {
        streamer.handlePTT(.start(sampleRate: 16000))  // trim window = 6400 bytes
        streamer.ingestPCM(Data(repeating: 0xAB, count: 10_000))
        XCTAssertEqual(sessionUpdates.last?.bytes, 10_000 - 6400,
                       "must flush only the bytes older than the 200 ms trailing window")
    }

    // MARK: handleControl JSON dispatch (BLE path)

    func testHandleControlStartParsesSampleRate() {
        streamer.handleControl("{\"type\":\"audio\",\"event\":\"start\",\"sample_rate\":8000}")
        XCTAssertEqual(sessionUpdates.last?.active, true)
        XCTAssertEqual(sessionUpdates.last?.sampleRate, 8000)
    }

    func testHandleControlStartDefaultsTo16kHz() {
        streamer.handleControl("{\"type\":\"audio\",\"event\":\"start\"}")
        XCTAssertEqual(sessionUpdates.last?.sampleRate, 16000)
    }

    func testHandleControlStopEndsSession() {
        streamer.handleControl("{\"type\":\"audio\",\"event\":\"start\",\"sample_rate\":16000}")
        streamer.handleControl("{\"type\":\"audio\",\"event\":\"stop\"}")
        XCTAssertEqual(sessionUpdates.last?.active, false)
        XCTAssertEqual(sessionEndedCount, 1)
    }

    func testHandleControlCancelTearsDown() {
        streamer.handleControl("{\"type\":\"audio\",\"event\":\"start\",\"sample_rate\":16000}")
        streamer.handleControl("{\"type\":\"audio\",\"event\":\"cancel\"}")
        XCTAssertEqual(sessionUpdates.last?.active, false)
        XCTAssertEqual(handler.rollbackCount, 0)
    }

    // MARK: onAudioFrame seq / gap accounting (BLE path)

    func testOnAudioFrameContinuousSeqHasNoGaps() {
        streamer.handlePTT(.start(sampleRate: 16000), tailTrimMs: 0)
        streamer.onAudioFrame(seq: 0, pcm: Data(repeating: 0, count: 100))
        streamer.onAudioFrame(seq: 1, pcm: Data(repeating: 0, count: 100))
        XCTAssertEqual(sessionUpdates.last?.gaps, 0)
        XCTAssertEqual(sessionUpdates.last?.bytes, 200)
    }

    func testOnAudioFrameDetectsAndPadsGap() {
        streamer.handlePTT(.start(sampleRate: 16000), tailTrimMs: 0)
        streamer.onAudioFrame(seq: 0, pcm: Data(repeating: 0, count: 100))
        // Skip seq 1 and 2 — expected=1 after first frame, jump to seq=3
        // produces gap=2 and pads 2×100=200 bytes of zeros before pcm.
        streamer.onAudioFrame(seq: 3, pcm: Data(repeating: 0, count: 100))
        XCTAssertEqual(sessionUpdates.last?.gaps, 2,
                       "two missing seqs must be counted")
        XCTAssertEqual(sessionUpdates.last?.bytes, 100 + 200 + 100,
                       "gap must inject pcm.count × gap zero bytes before the new frame")
    }

    func testOnAudioFrameDroppedWhenInactive() {
        // No start — onAudioFrame must early-return on !active.
        streamer.onAudioFrame(seq: 0, pcm: Data(repeating: 0, count: 100))
        XCTAssertEqual(sessionUpdates.count, 0)
    }
}
