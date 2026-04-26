import Foundation
import Combine
import VibeBuddyCore

// Top-level TextHandler the iOS app feeds into BLEController. It owns
// the two real handlers and forwards every call to both:
//
//   • PasteboardHandler runs unconditionally — writing to UIPasteboard
//     is the cheap safety net that lets the user paste into any other
//     app even when WebView injection isn't available or fails.
//   • WebViewInjector runs only when mode == .webview AND a WKWebView
//     is currently attached.
//
// The router itself is what BLEController gets handed at construction
// time; everything below sits behind the TextHandler interface so the
// shared package doesn't need to know about modes or WKWebView.
@MainActor
final class TextRouter: ObservableObject, TextHandler {

    enum Mode: String, Codable {
        case pasteboard
        case webview
    }

    @Published var mode: Mode = .pasteboard

    // The protocol requires this; we don't use it (neither sub-handler
    // demands a permission gate on iOS).
    var onPermissionRequired: (() -> Void)?

    let pasteboard: PasteboardHandler
    let webview: WebViewInjector

    init(pasteboard: PasteboardHandler, webview: WebViewInjector) {
        self.pasteboard = pasteboard
        self.webview = webview
    }

    func checkPermission() -> Bool { true }

    // MARK: TextHandler — fan out to both

    func update(to newText: String) {
        pasteboard.update(to: newText)
        if mode == .webview {
            webview.update(to: newText)
        }
    }

    func reset() {
        pasteboard.reset()
        webview.reset()   // reset always — new ASR session means stale
                          // mirror in either handler
    }

    func sendEnter() {
        pasteboard.sendEnter()
        if mode == .webview {
            webview.sendEnter()
        }
    }

    func sendBackspaceChar() {
        pasteboard.sendBackspaceChar()
        if mode == .webview {
            webview.sendBackspaceChar()
        }
    }

    func clearAll() {
        pasteboard.clearAll()
        if mode == .webview {
            webview.clearAll()
        }
    }

    func rollback() {
        pasteboard.rollback()
        if mode == .webview {
            webview.rollback()
        }
    }
}
