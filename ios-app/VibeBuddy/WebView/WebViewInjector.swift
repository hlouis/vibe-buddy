import Foundation
import WebKit
import VibeBuddyCore

// Pure value type representing one diff step the JS payload should
// apply to the focused element: delete N characters before the caret,
// then insert this string. Extracted as a top-level type so the diff
// algorithm can be unit-tested without standing up a WebPage.
struct TextDiff: Equatable {
    let deleteCount: Int
    let insertText: String

    // Longest-common-prefix diff: keep the part of `from` that's still
    // a prefix of `to`, delete everything after it, then insert
    // whatever's new. Counts characters as Swift Characters (graphemes),
    // so combining marks and emoji-with-skin-tone behave intuitively.
    static func compute(from: String, to: String) -> TextDiff {
        let common = from.commonPrefix(with: to).count
        let deleteCount = from.count - common
        let insertText: String
        if common < to.count {
            insertText = String(to[to.index(to.startIndex, offsetBy: common)...])
        } else {
            insertText = ""
        }
        return TextDiff(deleteCount: deleteCount, insertText: insertText)
    }

    var isNoOp: Bool { deleteCount == 0 && insertText.isEmpty }
}

// Result of the most recent JS injection. Surfaced to the status bar so
// the user can see "已注入到 textarea#prompt" or "无焦点 · 已存剪贴板".
enum InjectionResult: Equatable {
    case idle
    case ok(mode: String, focus: String)
    case noFocus
    case unsupported(focus: String)
    case exception(String)
}

// Drives the WebPage half of the iOS TextHandler split. Holds a weak
// reference to the BrowserState's WebPage (set when the browser tab
// appears, cleared when it disappears) and applies streaming ASR text
// as longest-common-prefix diffs through callJavaScript.
//
// Concurrency note: callJavaScript is async. ASR partials can fire
// faster than WebKit returns. We keep one in-flight call at a time and
// coalesce intermediate updates onto a single `pending` slot so a burst
// of partials collapses to "go from current mirror straight to the
// latest text" rather than typing every intermediate state.
//
// The class stays ObservableObject (not @Observable) on purpose:
// BrowserTabView already reads it via @EnvironmentObject and keeping
// the protocol means TextRouter / TextHandler don't need to learn a
// new shape for this migration.
@MainActor
final class WebViewInjector: ObservableObject, TextHandler {

    // The WebPage is owned by BrowserState; we keep a weak reference so
    // the injector doesn't extend its lifetime past tab dismissal.
    private weak var page: WebPage?

    // Mirror of what we believe the focused element currently contains
    // (just the portion we've typed). Cleared on every new ASR session.
    private var mirror: String = ""

    @Published var lastResult: InjectionResult = .idle
    @Published var focusInfo: String = ""
    @Published var focusInjectable: Bool = false
    // Mirrors window.__vbKbSuppressed in the page. Default true: focus
    // events do not pop the soft keyboard until the user toggles it on.
    @Published var keyboardSuppressed: Bool = true

    // Resolves the current per-site policy table at dispatch time.
    // Wired to PolicyStore by VibeBuddyApp so user-edited policies take
    // effect on the next BtnA press without restarting; defaults to
    // the bundled table so unit tests don't need to construct a store.
    var policyProvider: () -> [SiteKeyPolicy] = { SiteKeyPolicy.defaults }

    // Coalescing in-flight callJavaScript calls.
    private var inFlight: Bool = false
    private var pending: String?

    // No-op (TextHandler protocol requirement). iOS has no equivalent
    // permission gate for what we do here.
    var onPermissionRequired: (() -> Void)?
    func checkPermission() -> Bool { true }

    // MARK: lifecycle

    func attach(_ page: WebPage) {
        self.page = page
    }

    func detach() {
        self.page = nil
    }

    // Called when BrowserState's focus tracker posts a focusin /
    // focusout message. The status bar reads these directly.
    func updateFocus(descriptor: String, injectable: Bool) {
        self.focusInfo = descriptor
        self.focusInjectable = injectable
    }

    // MARK: TextHandler

    func update(to newText: String) {
        guard page != nil else { return }
        if inFlight {
            // Hold only the latest target — any intermediate partial
            // is obsolete the moment a newer one shows up.
            pending = newText
            return
        }
        runDiff(toward: newText)
    }

    func reset() {
        // New ASR session: drop our mirror so the next update(to:)
        // computes a fresh diff against an empty baseline. The actual
        // contents of the focused element aren't touched.
        mirror = ""
        pending = nil
    }

    func sendEnter() {
        // BtnA short-press: dispatch the per-site action. The policy
        // table comes from policyProvider so user-edited rules in the
        // settings UI take effect on the next press without an app
        // restart.
        let host = page?.url?.host
        let policy = SiteKeyPolicy.resolve(host: host, table: policyProvider())
        dispatchKeyAction(policy)
        // Caret moved (or the form just submitted) — either way, the
        // mirror no longer maps onto field contents.
        mirror = ""
    }

    func sendBackspaceChar() {
        // BtnB short-press: remove one character before caret.
        if !mirror.isEmpty { mirror = String(mirror.dropLast()) }
        applyOp(deleteCount: 1, insertText: "")
    }

    // Toolbar toggle: flip the in-page suppression flag and apply the
    // new mode to whatever is focused right now. Mutating inputmode on
    // the focused element hot-swaps the keyboard, so the user sees the
    // change immediately without us needing to blur/focus (which iOS
    // gates on user activation anyway).
    func toggleKeyboardSuppressed() {
        guard let page = page else { return }
        let next = !keyboardSuppressed
        keyboardSuppressed = next
        Task { @MainActor in
            do {
                _ = try await page.callJavaScript(
                    InjectionScript.setKeyboardSuppressed,
                    arguments: ["suppressed": next]
                )
            } catch {
                NSLog("[wv] toggleKeyboard error: %@", error.localizedDescription)
            }
        }
    }

    func clearAll() {
        // Long-press: wipe the focused field entirely.
        mirror = ""
        guard let page = page else { return }
        Task { @MainActor [weak self] in
            do {
                let result = try await page.callJavaScript(InjectionScript.clearAll)
                self?.handle(result: result)
            } catch {
                self?.lastResult = .exception(error.localizedDescription)
                NSLog("[wv] clearAll error: %@", error.localizedDescription)
            }
        }
    }

    func rollback() {
        // Session was cancelled; back out everything we typed this
        // session by deleting `mirror.count` chars and inserting
        // nothing. After this the mirror is empty.
        let n = mirror.count
        mirror = ""
        pending = nil
        guard n > 0 else { return }
        applyOp(deleteCount: n, insertText: "")
    }

    // MARK: private

    private func runDiff(toward newText: String) {
        let diff = TextDiff.compute(from: mirror, to: newText)
        mirror = newText
        if diff.isNoOp {
            // No-op, no need to round-trip into the webview.
            return
        }
        applyOp(deleteCount: diff.deleteCount, insertText: diff.insertText)
    }

    // BtnA dispatch goes through its own callJavaScript instead of
    // applyOp so the streaming-text inFlight/pending coalescer doesn't
    // get tangled up with one-shot key events. The race between an
    // in-flight ASR partial and a BtnA press is identical to the
    // pre-policy code (both used to fire callJavaScript without
    // mutual exclusion); not making it worse here.
    private func dispatchKeyAction(_ policy: SiteKeyPolicy) {
        guard let page = page else { return }
        let args = policy.dispatchArguments()
        Task { @MainActor [weak self] in
            do {
                let result = try await page.callJavaScript(
                    InjectionScript.dispatchKeyAction,
                    arguments: args
                )
                self?.handle(result: result)
            } catch {
                self?.lastResult = .exception(error.localizedDescription)
                NSLog("[wv] dispatchKey error: %@", error.localizedDescription)
            }
        }
    }

    private func applyOp(deleteCount: Int, insertText: String) {
        guard let page = page else { return }
        inFlight = true
        // Arguments cross the bridge as real JS values — no manual
        // string escaping, no JSON decoding on the way back. WebKit
        // marshals the returned JS object as [String: Any].
        let args: [String: Any] = [
            "deleteCount": deleteCount,
            "insertText": insertText,
        ]
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await page.callJavaScript(
                    InjectionScript.applyDiff,
                    arguments: args
                )
                self.handle(result: result)
            } catch {
                self.lastResult = .exception(error.localizedDescription)
                NSLog("[wv] inject error: %@", error.localizedDescription)
            }
            self.inFlight = false
            // If newer text arrived while we were busy, jump straight
            // to the latest target rather than re-running every
            // intermediate state we missed.
            if let p = self.pending {
                self.pending = nil
                self.runDiff(toward: p)
            }
        }
    }

    private func handle(result: Any?) {
        guard let dict = result as? [String: Any] else {
            self.lastResult = .exception("bad result")
            return
        }
        let ok = dict["ok"] as? Bool ?? false
        if ok {
            let mode = dict["mode"] as? String ?? "?"
            let focus = dict["focus"] as? String ?? ""
            self.lastResult = .ok(mode: mode, focus: focus)
        } else {
            switch dict["reason"] as? String {
            case "no-focus":
                self.lastResult = .noFocus
            case "unsupported":
                self.lastResult = .unsupported(focus: dict["focus"] as? String ?? "?")
            case "exception":
                self.lastResult = .exception(dict["error"] as? String ?? "?")
            default:
                self.lastResult = .exception("unknown")
            }
        }
    }
}
