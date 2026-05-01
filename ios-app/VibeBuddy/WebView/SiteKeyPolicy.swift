import Foundation

// Per-site policy for the hardware BtnA short-press action when the iOS
// app is in WebView injection mode. The streaming ASR text path
// (applyDiff) is unaffected; only the "the user clicked BtnA, do the
// site-specific newline-or-submit thing now" moment goes through here.
//
// Why per-site at all: BtnA's effect is a value judgement, not a
// physical fact. On ChatGPT the user often wants Enter (submit). On
// DeepSeek they often want Shift+Enter (insert a soft newline so they
// can keep dictating). The current chat sites all converge on the same
// keybindings (Enter=submit, Shift+Enter=newline) so resolving to a
// concrete KeyAction is a small lookup, not a UI engine.
//
// The match strategy is host-suffix only — first match wins. The
// catch-all entry has hostSuffix "*" and lives at the end of the table.
//
// V1 ships with code-defined defaults. A user-editable persistence
// layer (UserDefaults like BookmarkStore) is a follow-up; doing it now
// would be premature configurability when the defaults haven't even
// been validated against real sites yet.

struct KeyModifiers: OptionSet, Equatable, Hashable, Codable {
    let rawValue: Int
    static let shift = KeyModifiers(rawValue: 1 << 0)
    static let ctrl  = KeyModifiers(rawValue: 1 << 1)
    static let alt   = KeyModifiers(rawValue: 1 << 2)
    static let meta  = KeyModifiers(rawValue: 1 << 3)
}

// Four concrete dispatch strategies the JS payload knows how to
// execute. They exist as separate cases because no single strategy
// works on every chat site:
//
//   • insertText    — write a literal string via the textarea/input
//                      value setter (or execCommand on contenteditable).
//                      Bypasses isTrusted — this is the only path that
//                      reliably "types" into a vanilla <textarea>
//                      regardless of what the site's keydown handler
//                      checks for.
//   • keyEvent      — synthesize KeyboardEvent keydown/keyup. Works
//                      for React-based UIs that check `e.key` /
//                      `e.shiftKey` directly without an isTrusted
//                      gate. Caveat: synthetic events do NOT trigger
//                      browser default behaviour (e.g. inserting a
//                      newline into a focused textarea), and a site
//                      that gates submit on `e.isTrusted` will
//                      silently ignore them.
//   • beforeInput   — dispatch InputEvent('beforeinput', { inputType })
//                      on the focused element. Required for some
//                      ProseMirror/Slate editors that ignore synthetic
//                      KeyboardEvents but honour beforeinput.
//   • click         — querySelector + .click() a specific element on
//                      the page. The escape hatch for sites whose
//                      submit logic is gated on isTrusted: instead of
//                      forging a key event, we just press their
//                      "send" button directly. Selector is per-site
//                      and must be supplied by the policy table.
enum KeyAction: Equatable, Hashable, Codable {
    case insertText(String)
    case keyEvent(key: String, code: String, keyCode: Int, modifiers: KeyModifiers)
    case beforeInput(inputType: String, data: String?)
    case click(selector: String)

    static let insertNewline    = KeyAction.insertText("\n")
    static let pressEnter       = KeyAction.keyEvent(key: "Enter", code: "Enter",
                                                     keyCode: 13, modifiers: [])
    static let pressShiftEnter  = KeyAction.keyEvent(key: "Enter", code: "Enter",
                                                     keyCode: 13, modifiers: [.shift])
}

// User-facing presets. The detail UI picks one of these instead of
// exposing the raw enum cases so the user doesn't need to know what
// `keyCode` or `code` mean. Each preset round-trips to/from a
// concrete KeyAction via `KeyAction.preset` and `KeyAction(preset:…)`.
enum ActionPreset: String, CaseIterable, Identifiable, Codable {
    case pressEnter
    case pressShiftEnter
    case insertText
    case beforeInput
    case click

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pressEnter:      return "按下 Enter（提交消息）"
        case .pressShiftEnter: return "按下 Shift+Enter（软换行）"
        case .insertText:      return "插入文本"
        case .beforeInput:     return "beforeinput 事件"
        case .click:           return "点击页面元素"
        }
    }
}

extension KeyAction {
    // What preset bucket this action belongs in for the editor.
    // KeyEvent cases that aren't plain Enter / Shift+Enter still map
    // to one of those two — the UI doesn't expose arbitrary keys, so
    // a hand-edited custom keyEvent will display approximately and
    // serialise back into a preset on save. Acceptable for V1; if
    // someone needs Tab/Esc we add another preset.
    var preset: ActionPreset {
        switch self {
        case .insertText:                     return .insertText
        case .keyEvent(_, _, _, let mods):    return mods.contains(.shift) ? .pressShiftEnter : .pressEnter
        case .beforeInput:                    return .beforeInput
        case .click:                          return .click
        }
    }

    // One-line summary for the list row. Long selectors are truncated
    // so the row stays readable on a phone.
    var userLabel: String {
        switch self {
        case .insertText(let s):
            let display = s == "\n" ? "\\n" : (s.count > 16 ? String(s.prefix(16)) + "…" : s)
            return "插入文本: \(display)"
        case .keyEvent(_, _, _, let mods):
            return mods.contains(.shift) ? "Shift+Enter" : "Enter"
        case .beforeInput(let inputType, _):
            return "beforeinput · \(inputType)"
        case .click(let selector):
            let preview = selector.count > 28 ? String(selector.prefix(28)) + "…" : selector
            return "点击: \(preview)"
        }
    }
}

struct SiteKeyPolicy: Equatable, Hashable, Codable, Identifiable {
    var id: UUID = UUID()
    var hostSuffix: String
    var onBtnAClick: KeyAction

    // Sentinel for the catch-all row. The editor disables hostSuffix
    // editing and the delete swipe when this is true; PolicyStore
    // refuses to remove an entry whose hostSuffix is "*" regardless.
    var isCatchAll: Bool { hostSuffix == "*" }

    // Bundled defaults. Each entry says: when the foreground page's
    // host ends with this suffix, BtnA short-press dispatches this
    // action. The catch-all "*" entry MUST stay last; resolve() walks
    // the array top-to-bottom and the first non-"*" suffix that
    // matches wins.
    //
    // Seeded sites mirror BookmarkStore.presets where the chat-site
    // BtnA semantics are known. Sites the user explicitly named in
    // the design conversation (DeepSeek, ChatGPT/OpenAI) get the
    // exact mappings they asked for; the others stay on the
    // conservative insertNewline default until we have signal on
    // what the user actually wants.
    static let defaults: [SiteKeyPolicy] = [
        SiteKeyPolicy(hostSuffix: "chat.openai.com",   onBtnAClick: .pressEnter),
        SiteKeyPolicy(hostSuffix: "chatgpt.com",       onBtnAClick: .pressEnter),
        // DeepSeek's chat input is a vanilla <textarea> and its
        // submit logic gates on isTrusted, so synthesized
        // KeyboardEvents are silently swallowed. The send button has
        // no id, no data-testid, no aria-label — the only stable
        // anchor is the SVG path inside it (an upward arrow whose
        // d attribute starts with "M8.3125 0.981587"). The
        // surrounding class names are CSS-modules hashes that change
        // every deploy, so binding to them would rot fast. :has() is
        // supported in WKWebView on iOS 26.
        SiteKeyPolicy(
            hostSuffix: "chat.deepseek.com",
            onBtnAClick: .click(selector: "[role='button']:has(svg path[d^='M8.3125 0.981587'])")
        ),
        // Catch-all: send a synthetic Enter. This is the assumption
        // for chat-style AI sites — most of them treat Enter as
        // submit. For sites that gate on isTrusted nothing visible
        // happens; for sites that don't, the message is sent. The
        // previous default (insertText("\n")) was safer but useless
        // on the chat sites this app is actually used with.
        SiteKeyPolicy(hostSuffix: "*",                 onBtnAClick: .pressEnter),
    ]

    static func resolve(host: String?,
                        table: [SiteKeyPolicy] = defaults) -> SiteKeyPolicy {
        let h = (host ?? "").lowercased()
        for entry in table where entry.hostSuffix != "*" {
            if h.hasSuffix(entry.hostSuffix) { return entry }
        }
        if let fallback = table.last(where: { $0.hostSuffix == "*" }) {
            return fallback
        }
        // Defensive: if a caller hands us a table with no "*" row,
        // still produce a sane action rather than crashing.
        return SiteKeyPolicy(hostSuffix: "*", onBtnAClick: .insertNewline)
    }

    // Marshalled form for InjectionScript.dispatchKeyAction. WebKit
    // injects every key in this dictionary as a JS local in the
    // function body's scope — any variable the JS reads must exist
    // here even when the active branch doesn't need it, otherwise
    // the body throws ReferenceError before reaching the switch.
    func dispatchArguments() -> [String: Any] {
        switch onBtnAClick {
        case .insertText(let s):
            return Self.makeArgs(mode: "insertText", insertText: s)
        case .keyEvent(let key, let code, let keyCode, let mods):
            return Self.makeArgs(
                mode: "keyEvent",
                key: key, code: code, keyCode: keyCode,
                shiftKey: mods.contains(.shift),
                ctrlKey:  mods.contains(.ctrl),
                altKey:   mods.contains(.alt),
                metaKey:  mods.contains(.meta)
            )
        case .beforeInput(let inputType, let data):
            return Self.makeArgs(
                mode: "beforeInput",
                inputType: inputType,
                data: data ?? ""
            )
        case .click(let selector):
            return Self.makeArgs(mode: "click", selector: selector)
        }
    }

    private static func makeArgs(
        mode: String,
        insertText: String = "",
        key: String = "", code: String = "", keyCode: Int = 0,
        shiftKey: Bool = false, ctrlKey: Bool = false,
        altKey: Bool = false, metaKey: Bool = false,
        inputType: String = "", data: String = "",
        selector: String = ""
    ) -> [String: Any] {
        [
            "mode": mode,
            "insertText": insertText,
            "key": key,
            "code": code,
            "keyCode": keyCode,
            "shiftKey": shiftKey,
            "ctrlKey":  ctrlKey,
            "altKey":   altKey,
            "metaKey":  metaKey,
            "inputType": inputType,
            "data": data,
            "selector": selector,
        ]
    }
}
