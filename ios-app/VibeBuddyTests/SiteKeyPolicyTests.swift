import XCTest
@testable import VibeBuddy

// SiteKeyPolicy is the lookup that maps the foreground page's host to
// a concrete BtnA short-press action. The dispatch JS lives in
// InjectionScript and is shape-tested separately; here we pin down
// the resolution rules and the marshalling shape so a refactor of
// either side can't silently drift out of sync.
final class SiteKeyPolicyTests: XCTestCase {

    // MARK: lookup

    func testOpenAIResolvesToPlainEnter() {
        // User-stated requirement: on ChatGPT, BtnA short = submit.
        XCTAssertEqual(SiteKeyPolicy.resolve(host: "chat.openai.com").onBtnAClick,
                       .pressEnter)
        XCTAssertEqual(SiteKeyPolicy.resolve(host: "chatgpt.com").onBtnAClick,
                       .pressEnter)
    }

    func testDeepSeekResolvesToClickSendButton() {
        // DeepSeek gates its submit logic on isTrusted, so synthetic
        // KeyboardEvents are dead-on-arrival. The escape hatch is to
        // querySelector + .click() the actual send button. The site
        // gives us no stable id/data-testid/aria-label, so we anchor
        // on the SVG path coordinates of the upward-arrow icon.
        let action = SiteKeyPolicy.resolve(host: "chat.deepseek.com").onBtnAClick
        guard case .click(let selector) = action else {
            return XCTFail("expected .click, got \(action)")
        }
        XCTAssertTrue(selector.contains("M8.3125 0.981587"),
                      "selector lost the SVG-path anchor: \(selector)")
        XCTAssertTrue(selector.contains("role='button'"),
                      "selector lost the role=button predicate: \(selector)")
    }

    func testHostSuffixMatchIsCaseInsensitive() {
        // Hosts coming from URL.host can be mixed case in theory; the
        // lookup lowercases before comparing so users don't see
        // policies "vanish" because of capitalization.
        XCTAssertEqual(SiteKeyPolicy.resolve(host: "Chat.OpenAI.com").onBtnAClick,
                       .pressEnter)
    }

    func testSubdomainMatchesViaSuffix() {
        // hasSuffix-based matching means any subdomain of a known
        // host still resolves to its policy. www.chatgpt.com is a
        // realistic case (some users land there from search).
        XCTAssertEqual(SiteKeyPolicy.resolve(host: "www.chatgpt.com").onBtnAClick,
                       .pressEnter)
    }

    func testUnknownHostFallsBackToPressEnter() {
        // The "*" catch-all dispatches a synthetic Enter — the
        // assumption being that this app's user is mostly on chat
        // sites where Enter means submit. A site that gates submit
        // on isTrusted will silently swallow it (no harm done); a
        // site that doesn't will accept the message. The previous
        // default (insertText("\n")) was safer but useless on the
        // chat sites this app is actually used with.
        XCTAssertEqual(SiteKeyPolicy.resolve(host: "example.com").onBtnAClick,
                       .pressEnter)
    }

    func testNilHostFallsBack() {
        // Page hasn't loaded yet, or URL has no host (data: URLs etc.)
        XCTAssertEqual(SiteKeyPolicy.resolve(host: nil).onBtnAClick,
                       .pressEnter)
    }

    func testEmptyHostFallsBack() {
        XCTAssertEqual(SiteKeyPolicy.resolve(host: "").onBtnAClick,
                       .pressEnter)
    }

    func testCustomTableWithoutCatchAllStillReturnsSomething() {
        // Defensive contract: callers passing a hand-built table
        // that forgets the "*" row shouldn't crash. The synthesized
        // fallback is insertNewline — the most conservative option
        // (does *something* visible, never accidentally submits) for
        // the "library misuse" path. The product-level catch-all in
        // .defaults is a separate decision from this safety net.
        let table = [
            SiteKeyPolicy(hostSuffix: "only.example.com",
                          onBtnAClick: .pressEnter)
        ]
        let p = SiteKeyPolicy.resolve(host: "other.example.com", table: table)
        XCTAssertEqual(p.onBtnAClick, .insertNewline)
    }

    func testFirstMatchingEntryWins() {
        // Top-down resolution; a more specific suffix listed first
        // takes precedence over a broader one listed after.
        let table: [SiteKeyPolicy] = [
            SiteKeyPolicy(hostSuffix: "chat.special.example.com",
                          onBtnAClick: .pressShiftEnter),
            SiteKeyPolicy(hostSuffix: "example.com",
                          onBtnAClick: .pressEnter),
            SiteKeyPolicy(hostSuffix: "*", onBtnAClick: .insertNewline),
        ]
        XCTAssertEqual(
            SiteKeyPolicy.resolve(host: "chat.special.example.com",
                                  table: table).onBtnAClick,
            .pressShiftEnter)
        XCTAssertEqual(
            SiteKeyPolicy.resolve(host: "other.example.com",
                                  table: table).onBtnAClick,
            .pressEnter)
    }

    // MARK: dispatch arguments

    func testInsertTextArgumentsCarryTheString() {
        let p = SiteKeyPolicy(hostSuffix: "*", onBtnAClick: .insertText("\n"))
        let a = p.dispatchArguments()
        XCTAssertEqual(a["mode"] as? String, "insertText")
        XCTAssertEqual(a["insertText"] as? String, "\n")
    }

    func testKeyEventArgumentsCarryKeyAndModifiers() {
        let p = SiteKeyPolicy(hostSuffix: "*", onBtnAClick: .pressShiftEnter)
        let a = p.dispatchArguments()
        XCTAssertEqual(a["mode"] as? String, "keyEvent")
        XCTAssertEqual(a["key"] as? String, "Enter")
        XCTAssertEqual(a["code"] as? String, "Enter")
        XCTAssertEqual(a["keyCode"] as? Int, 13)
        XCTAssertEqual(a["shiftKey"] as? Bool, true)
        XCTAssertEqual(a["ctrlKey"] as? Bool, false)
        XCTAssertEqual(a["altKey"] as? Bool, false)
        XCTAssertEqual(a["metaKey"] as? Bool, false)
    }

    func testPlainEnterHasNoShift() {
        let p = SiteKeyPolicy(hostSuffix: "*", onBtnAClick: .pressEnter)
        XCTAssertEqual(p.dispatchArguments()["shiftKey"] as? Bool, false)
    }

    func testBeforeInputArgumentsCarryInputType() {
        let p = SiteKeyPolicy(hostSuffix: "*",
                              onBtnAClick: .beforeInput(inputType: "insertLineBreak",
                                                        data: nil))
        let a = p.dispatchArguments()
        XCTAssertEqual(a["mode"] as? String, "beforeInput")
        XCTAssertEqual(a["inputType"] as? String, "insertLineBreak")
        XCTAssertEqual(a["data"] as? String, "")
    }

    func testClickArgumentsCarrySelector() {
        let p = SiteKeyPolicy(hostSuffix: "*",
                              onBtnAClick: .click(selector: "button[role=\"button\"]"))
        let a = p.dispatchArguments()
        XCTAssertEqual(a["mode"] as? String, "click")
        XCTAssertEqual(a["selector"] as? String, "button[role=\"button\"]")
    }

    func testEveryModeFillsAllArgumentKeys() {
        // Critical contract with the JS side: WebKit's callJavaScript
        // makes every key a top-level local in the function body, and
        // any unset name throws ReferenceError before reaching the
        // mode-switch. Each KeyAction case must therefore produce a
        // dictionary with the full key set.
        let expectedKeys: Set<String> = [
            "mode", "insertText",
            "key", "code", "keyCode",
            "shiftKey", "ctrlKey", "altKey", "metaKey",
            "inputType", "data",
            "selector",
        ]
        let cases: [KeyAction] = [
            .insertText("\n"),
            .pressEnter,
            .pressShiftEnter,
            .beforeInput(inputType: "insertLineBreak", data: nil),
            .beforeInput(inputType: "insertParagraph", data: "x"),
            .click(selector: "#send"),
            .click(selector: "[role='button'][aria-label='Send']"),
        ]
        for action in cases {
            let p = SiteKeyPolicy(hostSuffix: "*", onBtnAClick: action)
            let keys = Set(p.dispatchArguments().keys)
            XCTAssertEqual(keys, expectedKeys,
                           "action \(action) is missing keys")
        }
    }
}
