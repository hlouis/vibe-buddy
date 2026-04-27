import XCTest
import UIKit
@testable import VibeBuddy

// PasteboardHandler does two things:
//   1. Maintain an in-app currentText / transcriptLog buffer the UI
//      observes via @Published.
//   2. Mirror the relevant text to UIPasteboard.general so the user
//      can switch apps and paste.
//
// These tests focus on (1) — the buffer logic is what differs from
// macOS. We touch UIPasteboard.general too but save / restore its
// contents in setUp / tearDown so test runs don't leak text into the
// host environment between cases.
@MainActor
final class PasteboardHandlerTests: XCTestCase {

    private var savedPasteboard: String?
    private var handler: PasteboardHandler!

    override func setUp() {
        super.setUp()
        savedPasteboard = UIPasteboard.general.string
        UIPasteboard.general.string = ""
        handler = PasteboardHandler()
    }

    override func tearDown() {
        UIPasteboard.general.string = savedPasteboard ?? ""
        super.tearDown()
    }

    // MARK: update / reset

    func testUpdateSetsCurrentText() {
        handler.update(to: "你好")
        XCTAssertEqual(handler.currentText, "你好")
        XCTAssertEqual(UIPasteboard.general.string, "你好")
    }

    func testUpdateEmptyDoesNotTouchPasteboard() {
        handler.update(to: "first")
        let beforeDate = handler.lastCopiedAt
        handler.update(to: "")
        // Empty update clears currentText but leaves the pasteboard
        // alone — clipboard mirroring is "preserve last useful copy."
        XCTAssertEqual(handler.currentText, "")
        XCTAssertEqual(handler.lastCopiedAt, beforeDate,
                       "lastCopiedAt should not advance on empty updates")
    }

    func testResetClearsCurrentTextOnly() {
        handler.update(to: "draft")
        handler.commitCurrentToLog()
        handler.update(to: "next")
        XCTAssertFalse(handler.transcriptLog.isEmpty)
        handler.reset()
        XCTAssertEqual(handler.currentText, "")
        XCTAssertEqual(handler.transcriptLog, ["draft"],
                       "reset is per-session — history must survive")
    }

    // MARK: edit actions

    func testCommitCurrentToLogTrimsAndAppends() {
        handler.update(to: "  hello  ")
        handler.commitCurrentToLog()
        XCTAssertEqual(handler.transcriptLog, ["hello"])
        XCTAssertEqual(handler.currentText, "")
    }

    func testCommitCurrentToLogIgnoresWhitespaceOnly() {
        handler.update(to: "   ")
        handler.commitCurrentToLog()
        XCTAssertTrue(handler.transcriptLog.isEmpty)
    }

    func testSendEnterCommitsAndUpdatesPasteboardWithJoinedLog() {
        handler.update(to: "first")
        handler.sendEnter()
        handler.update(to: "second")
        handler.sendEnter()
        XCTAssertEqual(handler.transcriptLog, ["first", "second"])
        XCTAssertEqual(UIPasteboard.general.string, "first\nsecond")
    }

    func testSendBackspaceTrimsLastCharOfCurrent() {
        handler.update(to: "abc")
        handler.sendBackspaceChar()
        XCTAssertEqual(handler.currentText, "ab")
        XCTAssertEqual(UIPasteboard.general.string, "ab")
    }

    func testSendBackspacePopsLogWhenCurrentEmpty() {
        handler.update(to: "first")
        handler.commitCurrentToLog()
        handler.update(to: "")
        XCTAssertEqual(handler.transcriptLog, ["first"])
        handler.sendBackspaceChar()
        XCTAssertTrue(handler.transcriptLog.isEmpty)
    }

    func testClearAllWipesEverything() {
        handler.update(to: "a")
        handler.commitCurrentToLog()
        handler.update(to: "b")
        handler.clearAll()
        XCTAssertEqual(handler.currentText, "")
        XCTAssertTrue(handler.transcriptLog.isEmpty)
        XCTAssertEqual(UIPasteboard.general.string, "")
    }

    func testRollbackClearsCurrentPreservesLog() {
        handler.update(to: "first")
        handler.commitCurrentToLog()
        handler.update(to: "in-flight")
        handler.rollback()
        XCTAssertEqual(handler.currentText, "")
        XCTAssertEqual(handler.transcriptLog, ["first"],
                       "rollback only undoes in-flight session, finalized history stays")
    }

    // MARK: copyAll / clearLog

    func testCopyAllJoinsLogAndCurrent() {
        handler.update(to: "alpha")
        handler.commitCurrentToLog()
        handler.update(to: "beta")
        handler.copyAll()
        XCTAssertEqual(UIPasteboard.general.string, "alpha\nbeta")
    }

    func testCopyAllSkipsEmptyTrailingCurrent() {
        handler.update(to: "alpha")
        handler.commitCurrentToLog()
        handler.update(to: "   ")
        handler.copyAll()
        XCTAssertEqual(UIPasteboard.general.string, "alpha")
    }

    func testClearLogPreservesCurrent() {
        handler.update(to: "one")
        handler.commitCurrentToLog()
        handler.update(to: "two")
        handler.clearLog()
        XCTAssertEqual(handler.transcriptLog, [])
        XCTAssertEqual(handler.currentText, "two")
    }
}
