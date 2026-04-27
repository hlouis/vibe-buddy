import XCTest
@testable import VibeBuddy

// TextDiff is the longest-common-prefix algorithm that drives both the
// macOS keystroke injector (transitively, in spirit) and the iOS
// WebView injector. ASR servers stream cumulative best-guess
// transcripts that may revise earlier text, and we need to translate
// each new cumulative state into "delete N, type M" so the user sees
// minimal flicker.
//
// These tests pin the algorithm down on Chinese / English mixed input,
// emoji, and a few well-known degenerate cases.
final class TextDiffTests: XCTestCase {

    func testEmptyToText() {
        let d = TextDiff.compute(from: "", to: "hello")
        XCTAssertEqual(d, TextDiff(deleteCount: 0, insertText: "hello"))
        XCTAssertFalse(d.isNoOp)
    }

    func testTextToEmpty() {
        let d = TextDiff.compute(from: "hello", to: "")
        XCTAssertEqual(d, TextDiff(deleteCount: 5, insertText: ""))
    }

    func testIdentityIsNoOp() {
        let d = TextDiff.compute(from: "same", to: "same")
        XCTAssertEqual(d, TextDiff(deleteCount: 0, insertText: ""))
        XCTAssertTrue(d.isNoOp)
    }

    func testGrowingPrefix() {
        // Typical streaming partial pattern: each update is the
        // previous text plus a few more characters.
        XCTAssertEqual(TextDiff.compute(from: "帮我",     to: "帮我查"),
                       TextDiff(deleteCount: 0, insertText: "查"))
        XCTAssertEqual(TextDiff.compute(from: "帮我查",   to: "帮我查一下"),
                       TextDiff(deleteCount: 0, insertText: "一下"))
        XCTAssertEqual(TextDiff.compute(from: "帮我查一下", to: "帮我查一下库存"),
                       TextDiff(deleteCount: 0, insertText: "库存"))
    }

    func testCorrectionRewritesTail() {
        // Doubao revising the last syllable: "白云" -> "帮我" (no
        // common prefix). Have to backspace both characters and
        // retype. This is the case the UI's "minimal flicker" claim
        // relies on most.
        let d = TextDiff.compute(from: "白云查", to: "帮我查")
        XCTAssertEqual(d, TextDiff(deleteCount: 3, insertText: "帮我查"))
    }

    func testPartialPrefixMatch() {
        let d = TextDiff.compute(from: "hello", to: "help")
        XCTAssertEqual(d, TextDiff(deleteCount: 2, insertText: "p"))
    }

    func testMixedASCIIAndCJK() {
        let d = TextDiff.compute(from: "Vibe Buddy 帮我", to: "Vibe Buddy 帮你")
        XCTAssertEqual(d, TextDiff(deleteCount: 1, insertText: "你"))
    }

    func testEmojiCountedAsSingleGrapheme() {
        // "你好👋" → "你好🎙": one grapheme replaced. The whole point
        // of using `commonPrefix` on String (not utf16/utf8 views) is
        // that emoji and combining marks behave intuitively.
        let d = TextDiff.compute(from: "你好👋", to: "你好🎙")
        XCTAssertEqual(d, TextDiff(deleteCount: 1, insertText: "🎙"))
    }

    func testWhitespaceChanges() {
        let d = TextDiff.compute(from: "hi there", to: "hi  there")
        XCTAssertEqual(d, TextDiff(deleteCount: 6, insertText: " there"))
    }

    func testNoOpDetection() {
        XCTAssertTrue(TextDiff(deleteCount: 0, insertText: "").isNoOp)
        XCTAssertFalse(TextDiff(deleteCount: 1, insertText: "").isNoOp)
        XCTAssertFalse(TextDiff(deleteCount: 0, insertText: "x").isNoOp)
    }
}
