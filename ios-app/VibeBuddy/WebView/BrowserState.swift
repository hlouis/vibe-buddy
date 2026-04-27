import Foundation
import Observation
import WebKit

// Owns the single SwiftUI WebView/WebPage the iOS app uses for in-app
// browsing. Constructed once at app startup and held by VibeBuddyApp so
// the user's session — login cookies, scroll position, page state —
// survives tab switches.
//
// On iOS 26 Apple shipped a first-class SwiftUI WebView (backed by an
// Observable WebPage). That collapses three things we used to maintain
// by hand into nothing:
//
//   • UIViewRepresentable bridge → gone (deleted WebViewRepresentable)
//   • KVO observers mirroring url/title/canGoBack/loadingProgress into
//     @Published copies → gone, WebPage exposes them as @Observable
//     properties directly
//   • WKNavigationDelegate / WKUIDelegate scaffolding → gone, we just
//     read isLoading; the legacy delegate dance was only ever there to
//     update the @Published mirrors
//
// The thing we *do* keep, untouched: WKUserContentController. It's
// exposed as `Configuration.userContentController` on WebPage, so our
// FocusBridge + focus-tracker user script wires up exactly the same way
// it did under WKWebView — that's what lets WebViewInjector know what
// element on the page is focused.
//
// @Observable (not ObservableObject) because that's what the SwiftUI
// WebPage uses. View consumers read it via @Environment(BrowserState.self).
@Observable
@MainActor
final class BrowserState {

    let page: WebPage

    // What the user typed into the address bar. Diverges from page.url
    // while typing, gets snapped back to the URL on every committed
    // navigation (see the load() method).
    var addressBarText: String = ""

    // Drained by the active load() so BrowserTabView's progress bar can
    // disappear after `.finished`. We could read page.isLoading
    // directly, but tracking it ourselves means we also flip false on
    // navigation errors, which the bare property doesn't.
    var isLoading: Bool = false

    // Read-through to WebPage. Defining these as computed (vs
    // duplicating into stored @Observable copies) means there's exactly
    // one source of truth — eliminates the "two mirrors drift" class of
    // bugs the old KVO scaffolding was prone to.
    var currentURL: URL? { page.url }
    var pageTitle: String { page.title }
    var loadingProgress: Double { page.estimatedProgress }
    var canGoBack: Bool { !page.backForwardList.backList.isEmpty }
    var canGoForward: Bool { !page.backForwardList.forwardList.isEmpty }

    // The injector reads these via a callback wired up at init time;
    // BrowserState itself just funnels JS focus messages through.
    var onFocusMessage: (@MainActor (_ descriptor: String, _ injectable: Bool) -> Void)?

    // Strong ref so the bridge outlives the configuration copy that
    // WebPage makes internally; UCC also retains it but holding here
    // too is the unambiguous fix.
    private let focusBridge = FocusBridge()

    init() {
        var cfg = WebPage.Configuration()

        // Inject our focus-tracker into every page at document end so
        // the status bar can show the focused element before the user
        // even speaks into the device. Same WKUserScript /
        // WKScriptMessageHandler API as before — Apple kept the
        // userContentController surface intact on WebPage.Configuration.
        let ucc = WKUserContentController()
        let focusScript = WKUserScript(
            source: InjectionScript.focusTracker,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        ucc.addUserScript(focusScript)
        ucc.add(focusBridge, name: "vbFocus")
        cfg.userContentController = ucc

        self.page = WebPage(configuration: cfg)

        // Bridge forwards messages back here once self exists.
        focusBridge.onMessage = { [weak self] body in
            guard let self else { return }
            let descriptor = (body["focus"] as? String) ?? ""
            let injectable = (body["injectable"] as? Bool) ?? false
            self.onFocusMessage?(descriptor, injectable)
        }
    }

    // MARK: navigation API

    func load(_ urlString: String) {
        let normalized = Self.normalizeURL(urlString)
        guard let url = URL(string: normalized) else { return }
        addressBarText = url.absoluteString
        consumeNavigationEvents(page.load(URLRequest(url: url)))
    }

    func goBack() {
        guard let item = page.backForwardList.backList.last else { return }
        consumeNavigationEvents(page.load(item))
    }

    func goForward() {
        guard let item = page.backForwardList.forwardList.first else { return }
        consumeNavigationEvents(page.load(item))
    }

    func reload() {
        consumeNavigationEvents(page.reload())
    }

    func stop() {
        page.stopLoading()
        isLoading = false
    }

    // Drives our `isLoading` mirror off the AsyncSequence returned by
    // every WebPage.load(...) variant. We don't strictly need the events
    // for anything else (the SwiftUI WebView paints itself), but
    // observing them is what lets us reset isLoading on either
    // .finished or thrown NavigationError — page.isLoading alone won't
    // tell us about provisional-nav failures.
    private func consumeNavigationEvents<S: AsyncSequence & Sendable>(_ seq: S)
        where S.Element == WebPage.NavigationEvent
    {
        Task { @MainActor [weak self] in
            self?.isLoading = true
            do {
                for try await event in seq {
                    if event == .finished {
                        self?.isLoading = false
                    }
                }
                self?.isLoading = false
            } catch {
                self?.isLoading = false
                NSLog("[wv] navigation failed: %@", String(describing: error))
            }
        }
    }

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

// Standalone message bridge so the WKUserContentController doesn't
// retain BrowserState (UCC takes a strong ref to whatever it gets via
// add(_:name:); a separate object lets BrowserState's lifecycle stay
// in our hands). The bridge captures BrowserState weakly via the
// `onMessage` callback. Same design as under the old WKWebView path.
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
