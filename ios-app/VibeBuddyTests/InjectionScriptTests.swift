import XCTest
@testable import VibeBuddy

// Smoke-tests for the JS payloads we ship into WebPage.callJavaScript.
//
// Pre-iOS-26 (legacy WKWebView path), arguments were passed via Swift
// string interpolation, so this file used to test a `jsString` escape
// helper and an `applyDiff(deleteCount:insertText:)` builder. Both went
// away with the move to WebPage.callJavaScript(_:arguments:) — the
// WebKit bridge marshals real JS values, so manual escaping no longer
// exists and there's nothing to unit-test there.
//
// What remains is verifying the *shape* of the function bodies we ship,
// so that anyone refactoring the JS doesn't accidentally drop a code
// path the runtime depends on (e.g. removes the contenteditable branch,
// or renames the `vbFocus` message channel out of sync with the native
// FocusBridge listener name).
final class InjectionScriptTests: XCTestCase {

    // MARK: applyDiff

    func testApplyDiffMentionsAllBranches() {
        // The applyDiff payload must dispatch on input/textarea, on
        // contenteditable, and explicitly handle no-focus. If a refactor
        // drops any of these, ASR text would silently fail to land in
        // some chat sites with no log to point at.
        let s = InjectionScript.applyDiff
        XCTAssertTrue(s.contains("INPUT"))
        XCTAssertTrue(s.contains("TEXTAREA"))
        XCTAssertTrue(s.contains("isContentEditable"))
        XCTAssertTrue(s.contains("'no-focus'"))
    }

    func testApplyDiffReadsArgumentsByName() {
        // WebPage.callJavaScript(_:arguments:) injects each entry of
        // the arguments dict as a local in the function body's scope.
        // The script depends on those exact names being present —
        // renaming them in WebViewInjector without updating here is
        // exactly the kind of silent breakage these tests guard.
        let s = InjectionScript.applyDiff
        XCTAssertTrue(s.contains("deleteCount"))
        XCTAssertTrue(s.contains("insertText"))
    }

    func testApplyDiffReturnsObjectNotJSONString() {
        // We rely on WebKit bridging the returned JS object to a Swift
        // [String: Any]. Pre-iOS-26 we used to JSON.stringify the
        // result and parse it back; if anyone re-introduces that here
        // the native side will spectacularly fail to match keys.
        let s = InjectionScript.applyDiff
        XCTAssertFalse(s.contains("JSON.stringify"),
                       "should return a JS object directly; the bridge marshals it")
        XCTAssertTrue(s.contains("return { ok: true"))
    }

    // MARK: clearAll

    func testClearAllScriptHasGuards() {
        let s = InjectionScript.clearAll
        XCTAssertTrue(s.contains("'no-focus'"),
                      "clearAll must report no-focus rather than crashing")
        XCTAssertTrue(s.contains("isContentEditable"))
        XCTAssertTrue(s.contains("selectAll"))
        XCTAssertFalse(s.contains("JSON.stringify"))
    }

    // MARK: focusTracker

    func testFocusTrackerInstallsListener() {
        // Just confirm the script we install at document-end includes
        // the moving parts we depend on: focusin/focusout listeners
        // and a postMessage to "vbFocus". The native side wires up
        // this exact name in BrowserState's FocusBridge.
        let s = InjectionScript.focusTracker
        XCTAssertTrue(s.contains("focusin"))
        XCTAssertTrue(s.contains("focusout"))
        XCTAssertTrue(s.contains("vbFocus"))
        XCTAssertTrue(s.contains("postMessage"))
    }
}
