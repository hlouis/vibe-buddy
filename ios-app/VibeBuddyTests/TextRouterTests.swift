import XCTest
@testable import VibeBuddy
import VibeBuddyCore

// TextRouter is the tiny dispatcher that fans every ASR-driven call
// out to the pasteboard and (conditionally) the webview handler. The
// dispatch rules are simple but load-bearing:
//
//   • update / sendEnter / sendBackspaceChar / clearAll / rollback
//     hit the pasteboard always, and the webview only when
//     mode == .webview.
//   • reset always hits both, regardless of mode (every new ASR
//     session must invalidate stale mirrors in either handler).
//
// These tests pin those rules down using two MockTextHandlers and
// assert the exact call sequence each one received.
@MainActor
final class TextRouterTests: XCTestCase {

    private var pasteboard: MockTextHandler!
    private var webview: MockTextHandler!
    private var router: TextRouter!

    override func setUp() {
        super.setUp()
        pasteboard = MockTextHandler()
        webview = MockTextHandler()
        router = TextRouter(pasteboard: pasteboard, webview: webview)
    }

    // MARK: pasteboard mode (default) — webview must stay quiet

    func testPasteboardModeUpdateOnlyHitsPasteboard() {
        router.mode = .pasteboard
        router.update(to: "你好")
        XCTAssertEqual(pasteboard.calls, [.update("你好")])
        XCTAssertEqual(webview.calls, [])
    }

    func testPasteboardModeEditActionsOnlyHitPasteboard() {
        router.mode = .pasteboard
        router.sendEnter()
        router.sendBackspaceChar()
        router.clearAll()
        router.rollback()
        XCTAssertEqual(pasteboard.calls, [.sendEnter, .sendBackspaceChar, .clearAll, .rollback])
        XCTAssertEqual(webview.calls, [])
    }

    // MARK: webview mode — both handlers fire (clipboard is the safety net)

    func testWebviewModeUpdateHitsBoth() {
        router.mode = .webview
        router.update(to: "hello")
        XCTAssertEqual(pasteboard.calls, [.update("hello")])
        XCTAssertEqual(webview.calls, [.update("hello")])
    }

    func testWebviewModeEditActionsHitBoth() {
        router.mode = .webview
        router.sendEnter()
        router.sendBackspaceChar()
        router.clearAll()
        router.rollback()
        let expected: [MockTextHandler.Call] =
            [.sendEnter, .sendBackspaceChar, .clearAll, .rollback]
        XCTAssertEqual(pasteboard.calls, expected)
        XCTAssertEqual(webview.calls, expected)
    }

    // MARK: reset is mode-independent

    func testResetAlwaysHitsBothInPasteboardMode() {
        router.mode = .pasteboard
        router.reset()
        XCTAssertEqual(pasteboard.calls, [.reset])
        XCTAssertEqual(webview.calls, [.reset],
                       "reset must clear webview mirror even in pasteboard mode, otherwise stale state lingers across sessions")
    }

    func testResetAlwaysHitsBothInWebviewMode() {
        router.mode = .webview
        router.reset()
        XCTAssertEqual(pasteboard.calls, [.reset])
        XCTAssertEqual(webview.calls, [.reset])
    }

    // MARK: mode-switch sequence

    func testSwitchingModesMidStreamRetargetsCorrectly() {
        // Simulates: pasteboard ASR session begins, user taps the
        // browser tab mid-utterance, next partial should also fan to
        // the webview.
        router.mode = .pasteboard
        router.update(to: "我想")
        router.mode = .webview
        router.update(to: "我想知道")
        XCTAssertEqual(pasteboard.calls, [.update("我想"), .update("我想知道")])
        XCTAssertEqual(webview.calls, [.update("我想知道")])
    }

    // MARK: protocol surface

    func testCheckPermissionAlwaysTrue() {
        XCTAssertTrue(router.checkPermission())
        // Router doesn't delegate this — neither sub-handler has a
        // permission gate on iOS.
        XCTAssertEqual(pasteboard.calls, [])
        XCTAssertEqual(webview.calls, [])
    }
}
