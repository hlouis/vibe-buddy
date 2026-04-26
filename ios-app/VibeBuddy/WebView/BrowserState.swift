import Foundation
import WebKit
import Combine

// Owns the single WKWebView the iOS app uses for in-app browsing,
// plus all the SwiftUI-observable navigation state that sits around it.
// Constructed once at app startup and held by VibeBuddyApp so the user's
// session — login cookies, scroll position, page state — survives tab
// switches.
//
// The matching WebViewInjector references the webview through this
// object. Keeping the webview here (not inside the View) is the standard
// SwiftUI pattern for UIKit-backed views that must outlive their
// representable wrapper.
@MainActor
final class BrowserState: NSObject, ObservableObject {

    let webView: WKWebView

    // What's actually in the address bar / loaded. currentURL updates
    // on every committed navigation; pendingURL is what the user typed
    // and hit go on (used while loading).
    @Published var currentURL: URL?
    @Published var addressBarText: String = ""
    @Published var pageTitle: String = ""
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var isLoading: Bool = false
    @Published var loadingProgress: Double = 0

    // The injector reads these via a callback wired up at init time;
    // BrowserState itself just funnels JS focus messages through.
    // Annotated @MainActor so call sites can synchronously talk to
    // @MainActor-isolated handlers without trampolining through Task.
    var onFocusMessage: (@MainActor (_ descriptor: String, _ injectable: Bool) -> Void)?

    // KVO observers so we can mirror WKWebView's progress / canGoBack
    // into @Published properties. Held as Any? so we can invalidate
    // them in deinit without touching their generic types.
    private var observers: [NSKeyValueObservation] = []
    // Strong ref so the bridge outlives the configuration copy that
    // WKWebView makes internally; UCC also retains it but holding
    // here too is the unambiguous fix.
    private let focusBridge = FocusBridge()

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.websiteDataStore = .default()  // share cookies across launches

        // Inject our focus-tracker into every page at document end so
        // the status bar can show the focused element before the user
        // even speaks into the device. We attach the message handler
        // BEFORE constructing the WKWebView because Apple's docs say
        // the configuration is copied internally; mutating the UCC
        // afterwards has historically been unreliable.
        let userContentController = WKUserContentController()
        let focusScript = WKUserScript(
            source: InjectionScript.focusTracker,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        userContentController.addUserScript(focusScript)
        userContentController.add(focusBridge, name: "vbFocus")
        cfg.userContentController = userContentController

        self.webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()

        // Bridge forwards messages back here once self exists.
        focusBridge.onMessage = { [weak self] body in
            guard let self else { return }
            let descriptor = (body["focus"] as? String) ?? ""
            let injectable = (body["injectable"] as? Bool) ?? false
            self.onFocusMessage?(descriptor, injectable)
        }

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // Mobile-Safari-ish UA so chat sites serve the touch-optimized
        // layout instead of detecting "WKWebView" and shipping a
        // stripped-down view (or, worse, refusing OAuth).
        webView.customUserAgent = nil  // let WebKit pick the iOS default

        observers = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.loadingProgress = wv.estimatedProgress }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.canGoBack = wv.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.canGoForward = wv.canGoForward }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.isLoading = wv.isLoading }
            },
            webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in
                    self?.currentURL = wv.url
                    if let s = wv.url?.absoluteString { self?.addressBarText = s }
                }
            },
            webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.pageTitle = wv.title ?? "" }
            },
        ]
    }

    deinit {
        observers.forEach { $0.invalidate() }
    }

    // MARK: navigation API

    func load(_ urlString: String) {
        let normalized = Self.normalizeURL(urlString)
        guard let url = URL(string: normalized) else { return }
        addressBarText = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    func goBack()    { if webView.canGoBack    { webView.goBack() } }
    func goForward() { if webView.canGoForward { webView.goForward() } }
    func reload()    { webView.reload() }
    func stop()      { webView.stopLoading() }

    // Accept "claude.ai", "https://claude.ai", and bare keywords (which
    // we punt to a search engine). Keep this dumb for now — the
    // shortcut menu is the primary UX, this is the escape hatch.
    static func normalizeURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        // Looks-like-a-host heuristic: contains a dot and no spaces.
        if trimmed.contains(".") && !trimmed.contains(" ") {
            return "https://" + trimmed
        }
        // Bing isn't great but at least doesn't gate the WebView like
        // Google sometimes does. The user can always type the full URL.
        let q = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return "https://www.bing.com/search?q=" + q
    }
}

// MARK: - Navigation delegate

extension BrowserState: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView,
                             didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in self.isLoading = true }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.isLoading = false }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.isLoading = false }
        NSLog("[wv] nav failed: %@", error.localizedDescription)
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in self.isLoading = false }
        NSLog("[wv] provisional nav failed: %@", error.localizedDescription)
    }

    // The WebKit content process has crashed — most commonly OOM on
    // memory-heavy chat pages. Reload the last URL so the user doesn't
    // see a blank white view.
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("[wv] content process terminated; reloading")
        Task { @MainActor in
            if let url = self.currentURL {
                webView.load(URLRequest(url: url))
            }
        }
    }
}

// MARK: - UI delegate (handle target=_blank)

extension BrowserState: WKUIDelegate {
    nonisolated func webView(_ webView: WKWebView,
                             createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction,
                             windowFeatures: WKWindowFeatures) -> WKWebView? {
        // No tabs in our UI yet — load target=_blank links inline.
        if let url = navigationAction.request.url {
            Task { @MainActor in webView.load(URLRequest(url: url)) }
        }
        return nil
    }
}

// Standalone message bridge so the WKUserContentController doesn't
// retain BrowserState (UCC takes a strong ref to whatever it gets via
// add(_:name:); a separate object lets BrowserState's lifecycle stay
// in our hands). The bridge captures BrowserState weakly via the
// `onMessage` callback.
private final class FocusBridge: NSObject, WKScriptMessageHandler {
    var onMessage: (@MainActor ([String: Any]) -> Void)?

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        guard message.name == "vbFocus",
              let body = message.body as? [String: Any] else { return }
        Task { @MainActor in
            self.onMessage?(body)
        }
    }
}
