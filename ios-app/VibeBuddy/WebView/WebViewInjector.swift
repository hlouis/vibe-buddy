import Foundation
import WebKit
import VibeBuddyCore

// Result of the most recent JS injection. Surfaced to the status bar so
// the user can see "已注入到 textarea#prompt" or "无焦点 · 已存剪贴板".
enum InjectionResult: Equatable {
    case idle
    case ok(mode: String, focus: String)
    case noFocus
    case unsupported(focus: String)
    case exception(String)
}

// Drives the WKWebView half of the iOS TextHandler split. Holds a weak
// reference to the BrowserState's WKWebView (set when the browser tab
// appears, cleared when it disappears) and applies streaming ASR text
// as longest-common-prefix diffs through evaluateJavaScript.
//
// Concurrency note: evaluateJavaScript is async. ASR partials can fire
// faster than WKWebView returns. We keep one in-flight call at a time
// and coalesce intermediate updates onto a single `pending` slot so a
// burst of partials collapses to "go from current mirror straight to
// the latest text" rather than typing every intermediate state.
@MainActor
final class WebViewInjector: ObservableObject, TextHandler {

    // The WKWebView is owned by BrowserState; we keep a weak reference
    // so the injector doesn't extend the webview's lifetime past tab
    // dismissal.
    private weak var webView: WKWebView?

    // Mirror of what we believe the focused element currently contains
    // (just the portion we've typed). Cleared on every new ASR session.
    private var mirror: String = ""

    @Published var lastResult: InjectionResult = .idle
    @Published var focusInfo: String = ""
    @Published var focusInjectable: Bool = false

    // Coalescing in-flight evaluateJavaScript calls.
    private var inFlight: Bool = false
    private var pending: String?

    // No-op (TextHandler protocol requirement). iOS has no equivalent
    // permission gate for what we do here.
    var onPermissionRequired: (() -> Void)?
    func checkPermission() -> Bool { true }

    // MARK: lifecycle

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    func detach() {
        self.webView = nil
    }

    // Called when BrowserState's focus tracker posts a focusin /
    // focusout message. The status bar reads these directly.
    func updateFocus(descriptor: String, injectable: Bool) {
        self.focusInfo = descriptor
        self.focusInjectable = injectable
    }

    // MARK: TextHandler

    func update(to newText: String) {
        guard webView != nil else { return }
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
        // BtnA double-tap: insert a newline into the focused element.
        // For textarea this is a literal "\n"; for contenteditable
        // execCommand('insertText','\n') generally lands as <br>, which
        // is what the user expects from a soft return. Newer rich
        // editors might intercept Enter for "send message" — that's
        // their prerogative; we still try.
        applyOp(deleteCount: 0, insertText: "\n")
        // Cursor moved on; mirror no longer maps onto field contents.
        mirror = ""
    }

    func sendBackspaceChar() {
        // BtnB short-press: remove one character before caret.
        if !mirror.isEmpty { mirror = String(mirror.dropLast()) }
        applyOp(deleteCount: 1, insertText: "")
    }

    func clearAll() {
        // Long-press: wipe the focused field entirely.
        mirror = ""
        guard let webView = webView else { return }
        webView.evaluateJavaScript(InjectionScript.clearAll) { [weak self] result, error in
            Task { @MainActor in
                self?.handleResult(result, error: error)
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
        let common = mirror.commonPrefix(with: newText).count
        let deleteCount = mirror.count - common
        let insertText: String
        if common < newText.count {
            let start = newText.index(newText.startIndex, offsetBy: common)
            insertText = String(newText[start...])
        } else {
            insertText = ""
        }
        mirror = newText
        if deleteCount == 0 && insertText.isEmpty {
            // No-op, no need to round-trip into the webview.
            return
        }
        applyOp(deleteCount: deleteCount, insertText: insertText)
    }

    private func applyOp(deleteCount: Int, insertText: String) {
        guard let webView = webView else { return }
        inFlight = true
        let script = InjectionScript.applyDiff(
            deleteCount: deleteCount, insertText: insertText
        )
        webView.evaluateJavaScript(script) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                self.handleResult(result, error: error)
                self.inFlight = false
                // If newer text arrived while we were busy, jump
                // straight to the latest target rather than re-running
                // every intermediate state we missed.
                if let p = self.pending {
                    self.pending = nil
                    self.runDiff(toward: p)
                }
            }
        }
    }

    private func handleResult(_ result: Any?, error: Error?) {
        if let error = error {
            self.lastResult = .exception(error.localizedDescription)
            NSLog("[wv] inject error: %@", error.localizedDescription)
            return
        }
        guard
            let json = result as? String,
            let data = json.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
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
