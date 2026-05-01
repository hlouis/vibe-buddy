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

    // MARK: dispatchKeyAction

    func testDispatchKeyActionHandlesAllFourModes() {
        // The JS payload dispatches on a `mode` string injected as a
        // local. SiteKeyPolicy.dispatchArguments produces four values
        // for that field; if a refactor drops any branch, BtnA on the
        // affected sites would silently fail with no log.
        let s = InjectionScript.dispatchKeyAction
        XCTAssertTrue(s.contains("'insertText'"))
        XCTAssertTrue(s.contains("'keyEvent'"))
        XCTAssertTrue(s.contains("'beforeInput'"))
        XCTAssertTrue(s.contains("'click'"))
    }

    func testClickBranchUsesQuerySelector() {
        // Click is the escape hatch for sites that gate submit on
        // isTrusted; we don't try to forge a key event, we locate
        // the actual button. querySelector + .click() is the
        // contract — if anyone refactors to find-by-id-only or drops
        // the branch entirely, sites configured with .click()
        // policies would silently no-op.
        let s = InjectionScript.dispatchKeyAction
        XCTAssertTrue(s.contains("querySelector"))
        XCTAssertTrue(s.contains(".click()"))
        XCTAssertTrue(s.contains("'no-target'"),
                      "click branch must report missing element rather than crashing")
    }

    func testDispatchKeyActionUsesKeyboardAndInputEvents() {
        // keyEvent branch must construct real KeyboardEvent (not a
        // generic Event); beforeInput branch must dispatch InputEvent
        // with the inputType property — those are exactly the shapes
        // chat-site editors check for.
        let s = InjectionScript.dispatchKeyAction
        XCTAssertTrue(s.contains("KeyboardEvent"))
        XCTAssertTrue(s.contains("InputEvent"))
        XCTAssertTrue(s.contains("'beforeinput'"))
        XCTAssertTrue(s.contains("inputType"))
    }

    func testDispatchKeyActionGuardsNoFocus() {
        // Same protocol as the other payloads: returning ok=false with
        // a 'no-focus' reason lets the Swift status bar show "无焦点"
        // instead of an opaque exception.
        let s = InjectionScript.dispatchKeyAction
        XCTAssertTrue(s.contains("'no-focus'"))
        XCTAssertFalse(s.contains("JSON.stringify"))
    }

    func testDispatchKeyActionReadsAllNamedArguments() {
        // WebKit injects every key from the Swift dictionary as a
        // local in the function body. The JS unconditionally references
        // these names — if SiteKeyPolicy.dispatchArguments stops
        // populating any of them, the body throws ReferenceError before
        // even reaching the mode switch.
        let s = InjectionScript.dispatchKeyAction
        for name in ["mode", "insertText", "key", "code", "keyCode",
                     "shiftKey", "ctrlKey", "altKey", "metaKey",
                     "inputType", "data", "selector"] {
            XCTAssertTrue(s.contains(name),
                          "dispatchKeyAction must reference `\(name)`")
        }
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
