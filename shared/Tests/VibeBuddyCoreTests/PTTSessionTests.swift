import XCTest
@testable import VibeBuddyCore

// PTTSession is the cross-platform press/release state machine that
// every PTT trigger (macOS HotKeyPTTTrigger, iOS ButtonPTTTrigger,
// future Stream Deck / MIDI / BLE button) funnels its edges through.
// Three behaviours absolutely must not regress:
//
//   1. Idempotent down() — key autorepeat must not start a new session.
//   2. Short-press → cancel, long-press → stop — the 350 ms split point
//      mirrors the firmware so muscle memory stays consistent.
//   3. Watchdog forces a stop if up() never arrives — covers Mission
//      Control / phone-call / backgrounding scenarios that eat the
//      release edge and would otherwise stream audio forever.
//
// These cover the contract that AudioSourceCoordinator (both platforms)
// relies on now that mic-engine lifecycle is bound to PTT edges.
@MainActor
final class PTTSessionTests: XCTestCase {

    private var session: PTTSession!
    private var events: [PTTEvent] = []

    override func setUp() {
        super.setUp()
        session = PTTSession()
        events = []
        session.onEvent = { [weak self] event in self?.events.append(event) }
    }

    override func tearDown() {
        session = nil
        events = []
        super.tearDown()
    }

    // MARK: down/up basics

    func testDownEmitsStartWithDefaultSampleRate() {
        session.down()
        XCTAssertEqual(events, [.start(sampleRate: 16000)])
        XCTAssertTrue(session.isPressed)
    }

    func testDownIsIdempotentAgainstAutorepeat() {
        session.down()
        session.down()
        session.down()
        XCTAssertEqual(events, [.start(sampleRate: 16000)],
                       "down() must be a no-op while already pressed (key autorepeat)")
    }

    func testUpWithoutDownIsNoop() {
        session.up()
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(session.isPressed)
    }

    func testRespectsCustomSampleRate() {
        session.sampleRate = 8000
        session.down()
        XCTAssertEqual(events, [.start(sampleRate: 8000)])
    }

    // MARK: short vs long press classification

    func testShortPressEmitsCancel() async throws {
        session.shortPressMs = 100
        session.down()
        try await Task.sleep(nanoseconds: 30_000_000)  // 30 ms < 100 ms threshold
        session.up()
        XCTAssertEqual(events, [.start(sampleRate: 16000), .cancel])
        XCTAssertFalse(session.isPressed)
    }

    func testLongPressEmitsStop() async throws {
        session.shortPressMs = 30
        session.down()
        try await Task.sleep(nanoseconds: 80_000_000)  // 80 ms > 30 ms threshold
        session.up()
        XCTAssertEqual(events, [.start(sampleRate: 16000), .stop])
        XCTAssertFalse(session.isPressed)
    }

    // MARK: watchdog
    //
    // The watchdog only matters when up() is *lost*. With short maxHoldSec
    // we can prove (a) the watchdog fires .stop and (b) a normal release
    // cancels the watchdog so it doesn't fire a second time.

    func testWatchdogForcesStopWhenUpIsLost() async throws {
        session.maxHoldSec = 0.05
        session.down()
        try await Task.sleep(nanoseconds: 200_000_000)  // 4× the watchdog
        XCTAssertEqual(events, [.start(sampleRate: 16000), .stop],
                       "watchdog must synthesise a .stop when no up() arrives")
        XCTAssertFalse(session.isPressed)
    }

    func testWatchdogCancelledByNormalRelease() async throws {
        session.shortPressMs = 10
        session.maxHoldSec = 0.10
        session.down()
        try await Task.sleep(nanoseconds: 30_000_000)
        session.up()
        let eventsAfterUp = events
        try await Task.sleep(nanoseconds: 200_000_000)  // 2× the watchdog
        XCTAssertEqual(events, eventsAfterUp,
                       "watchdog must be cancelled on normal release")
    }

    // MARK: reset
    //
    // reset() is the API AudioSourceCoordinator can use to force-clear
    // the trigger when the engine fails mid-press or the host switches
    // audio sources during a hold.

    func testResetWhilePressedEmitsCancel() {
        session.down()
        session.reset()
        XCTAssertEqual(events, [.start(sampleRate: 16000), .cancel])
        XCTAssertFalse(session.isPressed)
    }

    func testResetWhenIdleIsSilent() {
        session.reset()
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(session.isPressed)
    }

    func testCanRepressAfterReset() {
        session.down()
        session.reset()
        events.removeAll()
        session.down()
        XCTAssertEqual(events, [.start(sampleRate: 16000)],
                       "down() must accept a fresh press after reset()")
        XCTAssertTrue(session.isPressed)
    }

    func testResetCancelsWatchdog() async throws {
        session.maxHoldSec = 0.05
        session.down()
        session.reset()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(events, [.start(sampleRate: 16000), .cancel],
                       "watchdog must not fire after reset()")
    }
}
