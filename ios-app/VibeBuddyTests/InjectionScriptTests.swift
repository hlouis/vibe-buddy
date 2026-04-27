import XCTest
@testable import VibeBuddy

// The JS payloads we ship into WKWebView are constructed by string
// interpolation. A bug in the escape function would either silently
// change the meaning of injected text (e.g. dropping a backslash) or
// blow up with a JavaScript SyntaxError that surfaces only at runtime
// against a real webview. These tests pin escaping down statically.
final class InjectionScriptTests: XCTestCase {

    // MARK: jsString — the escape primitive

    func testEscapeASCIIPassthrough() {
        XCTAssertEqual(InjectionScript.jsString("hello"), "\"hello\"")
    }

    func testEscapeEmpty() {
        XCTAssertEqual(InjectionScript.jsString(""), "\"\"")
    }

    func testEscapeBackslash() {
        // One backslash in input -> two in JS literal (\\) ->
        // four in our Swift literal here.
        XCTAssertEqual(InjectionScript.jsString("\\"), "\"\\\\\"")
    }

    func testEscapeDoubleQuote() {
        XCTAssertEqual(InjectionScript.jsString("\""), "\"\\\"\"")
    }

    func testEscapeNewlineAndCR() {
        XCTAssertEqual(InjectionScript.jsString("\n"), "\"\\n\"")
        XCTAssertEqual(InjectionScript.jsString("\r"), "\"\\r\"")
        XCTAssertEqual(InjectionScript.jsString("\t"), "\"\\t\"")
    }

    func testEscapeUnicodeLineSeparators() {
        // U+2028 LINE SEPARATOR and U+2029 PARAGRAPH SEPARATOR are
        // valid string contents in most languages but break JS string
        // literals — they're treated as line terminators by the JS
        // tokenizer. Must escape.
        XCTAssertEqual(InjectionScript.jsString("\u{2028}"), "\"\\u2028\"")
        XCTAssertEqual(InjectionScript.jsString("\u{2029}"), "\"\\u2029\"")
    }

    func testEscapeControlChar() {
        // 0x01 (Start-of-Heading) — encoded as .
        XCTAssertEqual(InjectionScript.jsString("\u{01}"), "\"\\u0001\"")
    }

    func testEscapeChinesePassthrough() {
        // Chinese / CJK characters are above 0x20 and don't need
        // escaping; they pass through verbatim.
        XCTAssertEqual(InjectionScript.jsString("你好"), "\"你好\"")
    }

    func testEscapeMixedContent() {
        let mixed = InjectionScript.jsString("a\nb\"c\\d")
        XCTAssertEqual(mixed, "\"a\\nb\\\"c\\\\d\"")
    }

    // MARK: applyDiff — full payload assembly

    func testApplyDiffEmbedsBothArguments() {
        let script = InjectionScript.applyDiff(deleteCount: 3, insertText: "你好")
        // The final invocation of the IIFE must carry the literal
        // delete count and the escaped insert string.
        XCTAssertTrue(script.contains("})(3, \"你好\");"),
                      "expected final invocation '})(3, \"你好\");' in: \(script.suffix(80))")
    }

    func testApplyDiffEscapesInsertText() {
        let script = InjectionScript.applyDiff(deleteCount: 0, insertText: "a\nb")
        // Newline must be escaped, not literal — otherwise the JS
        // parser hits an unterminated string literal at the line break.
        XCTAssertTrue(script.contains("(0, \"a\\nb\")"),
                      "newline in insertText must be backslash-n escaped")
        XCTAssertFalse(script.contains("\"a\nb\""),
                       "raw newline must not appear inside the JS literal")
    }

    func testApplyDiffHandlesEmptyInsert() {
        let script = InjectionScript.applyDiff(deleteCount: 5, insertText: "")
        XCTAssertTrue(script.contains("})(5, \"\");"))
    }

    func testApplyDiffMentionsBothBranches() {
        // Smoke-check that the script we ship still has the three
        // dispatch branches we documented (input/textarea, content-
        // editable, fallback). If someone refactors and accidentally
        // drops one, this test catches it before we hit a real site.
        let script = InjectionScript.applyDiff(deleteCount: 0, insertText: "x")
        XCTAssertTrue(script.contains("INPUT"))
        XCTAssertTrue(script.contains("TEXTAREA"))
        XCTAssertTrue(script.contains("isContentEditable"))
        XCTAssertTrue(script.contains("'no-focus'"))
    }

    // MARK: focusTracker / clearAll smoke

    func testFocusTrackerInstallsListener() {
        // Just confirm the script we install at document-end includes
        // the moving parts we depend on: focusin/focusout listeners
        // and a postMessage to "vbFocus". The native side wires up
        // this exact name in BrowserState.
        let s = InjectionScript.focusTracker
        XCTAssertTrue(s.contains("focusin"))
        XCTAssertTrue(s.contains("focusout"))
        XCTAssertTrue(s.contains("vbFocus"))
        XCTAssertTrue(s.contains("postMessage"))
    }

    func testClearAllScriptHasGuards() {
        let s = InjectionScript.clearAll
        XCTAssertTrue(s.contains("'no-focus'"),
                      "clearAll must report no-focus rather than crashing")
        XCTAssertTrue(s.contains("isContentEditable"))
        XCTAssertTrue(s.contains("selectAll"))
    }
}
