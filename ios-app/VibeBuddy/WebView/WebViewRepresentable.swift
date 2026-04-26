import SwiftUI
import WebKit

// SwiftUI wrapper around the long-lived WKWebView held by BrowserState.
// The webview is constructed once at app startup; this representable
// just hands it to UIKit each time the browser tab appears. Doing it
// this way (rather than constructing in makeUIView) is what lets the
// page state — login cookies, scroll position, whatever's in the
// textarea — survive switching to another tab and back.
struct WebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Navigation is driven imperatively through BrowserState; nothing
        // to reconcile from SwiftUI state.
    }
}
