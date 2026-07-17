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

    // Lazily constructed on first access — must NOT be made eager.
    // Constructing a WebPage spawns the WebContent helper process. On
    // iPadOS 26 that helper can't acquire long-lived RBS assertions
    // (the app doesn't carry the `com.apple.developer.web-browser-
    // engine.*` entitlements Safari does), so when WebContent is
    // spawned without a visible WKWebView holding it, the system kills
    // and respawns it on a tight loop. The user's first tap into the
    // browser then lands inside that process-restart window, the
    // gesture-delay queue picks up a nil UITouch, and UIKit aborts in
    // -[UIGestureRecognizer _delayTouchesForEvent:inPhase:] →
    // [__NSArrayM insertObject:atIndex:]. Deferring creation until
    // BrowserTabView reads `page` means WebContent is born under a
    // foreground WKWebView assertion and never enters that race.
    var page: WebPage {
        if let p = _page { return p }
        let p = makePage()
        _page = p
        return p
    }

    // @ObservationIgnored because the nil→non-nil transition fires
    // synchronously inside a body re-evaluation; we don't want to
    // invalidate the body that just produced our value.
    @ObservationIgnored private var _page: WebPage?

    // What the user typed into the address bar. Diverges from page.url
    // while typing, gets snapped back to the URL on every committed
    // navigation (see the load() method).
    var addressBarText: String = ""

    // Drained by the active load() so BrowserTabView's progress bar can
    // disappear after `.finished`. We could read page.isLoading
    // directly, but tracking it ourselves means we also flip false on
    // navigation errors, which the bare property doesn't.
    var isLoading: Bool = false

    // Read-through to WebPage *without* forcing creation — the
    // VibeBuddyApp front-app status pipe polls these on app launch,
    // long before the user opens the browser tab, so they must not be
    // the thing that triggers WebContent. Defaults match what an empty
    // WebPage would report.
    var currentURL: URL? { _page?.url }
    var pageTitle: String { _page?.title ?? "" }
    var loadingProgress: Double { _page?.estimatedProgress ?? 0 }
    var canGoBack: Bool { _page.map { !$0.backForwardList.backList.isEmpty } ?? false }
    var canGoForward: Bool { _page.map { !$0.backForwardList.forwardList.isEmpty } ?? false }

    // The injector reads these via a callback wired up at init time;
    // BrowserState itself just funnels JS focus messages through.
    var onFocusMessage: (@MainActor (_ descriptor: String, _ injectable: Bool) -> Void)?

    // Strong ref so the bridge outlives the configuration copy that
    // WebPage makes internally; UCC also retains it but holding here
    // too is the unambiguous fix.
    private let focusBridge = FocusBridge()
    private let blobBridge = BlobDownloadBridge()

    // Owns the in-browser download pipeline. Held here (not at App
    // level) so the navigation decider — also constructed in
    // makePage() — has a single, lifetime-aligned reference. Exposed
    // via the page environment to BrowserTabView for status/share UI.
    let downloads: BrowserDownloadManager

    // No default argument: BrowserDownloadManager.init is @MainActor
    // (the type is) and default expressions evaluate in a nonisolated
    // context, which would fail the actor check. Caller supplies the
    // manager — VibeBuddyApp's @MainActor init does this naturally.
    init(downloads: BrowserDownloadManager) {
        self.downloads = downloads
        // Bridge callback wired up here; makePage() attaches the bridge
        // to the user content controller whenever the page is finally
        // constructed.
        focusBridge.onMessage = { [weak self] body in
            guard let self else { return }
            let descriptor = (body["focus"] as? String) ?? ""
            let injectable = (body["injectable"] as? Bool) ?? false
            self.onFocusMessage?(descriptor, injectable)
        }
        // Blob/data-URL downloads come in here. The JS hook ships a
        // single dictionary per fired download — either {dataUrl,
        // filename, mime, size} on success or {error, filename} on
        // failure / oversize. We forward straight to the manager,
        // which owns dedup + temp-file landing + share-sheet trigger.
        blobBridge.onMessage = { [weak self] body in
            guard let self else { return }
            let filename = (body["filename"] as? String) ?? "download"
            if let err = body["error"] as? String {
                self.downloads.appendFailedInline(filename: filename, reason: err)
                return
            }
            guard let dataUrl = body["dataUrl"] as? String else { return }
            let mime = (body["mime"] as? String) ?? "application/octet-stream"
            let size = (body["size"] as? Int) ?? 0
            self.downloads.startFromInlineData(
                dataUrl: dataUrl,
                filename: filename,
                mime: mime,
                size: size
            )
        }
    }

    private func makePage() -> WebPage {
        var cfg = WebPage.Configuration()
        // Explicit so the cookies the decider hands to URLSession come
        // from the same jar the WebView is actually using. The default
        // would be `.default()` anyway, but pinning it makes the
        // contract obvious.
        cfg.websiteDataStore = .default()

        // Inject our focus-tracker into every page at document end so
        // the status bar can show the focused element before the user
        // even speaks into the device. Same WKUserScript /
        // WKScriptMessageHandler API as before — Apple kept the
        // userContentController surface intact on WebPage.Configuration.
        let ucc = WKUserContentController()
        // Blob/data download interceptor MUST go in at document-start
        // and ahead of every other script — we're monkey-patching
        // HTMLAnchorElement.prototype.click, and any page script that
        // captures the original click before we do will route around
        // us. forMainFrameOnly:false so SPAs that put their export
        // logic inside a same-origin iframe still get covered.
        let blobScript = WKUserScript(
            source: InjectionScript.blobDownloadHook,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        ucc.addUserScript(blobScript)
        let focusScript = WKUserScript(
            source: InjectionScript.focusTracker,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        ucc.addUserScript(focusScript)
        // Suppress iOS's auto-popup soft keyboard by default. The toolbar
        // toggle in BrowserTabView flips window.__vbKbSuppressed so the
        // user can summon the keyboard on demand.
        let kbScript = WKUserScript(
            source: InjectionScript.keyboardSuppressor,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        ucc.addUserScript(kbScript)
        ucc.add(focusBridge, name: "vbFocus")
        ucc.add(blobBridge, name: "vbDownload")
        cfg.userContentController = ucc

        // Navigation decider intercepts download-intent navigations
        // (HTML5 `<a download>`, non-renderable MIME types,
        // Content-Disposition: attachment) and hands them to our
        // BrowserDownloadManager, which re-fetches via URLSession with
        // matching cookies. SwiftUI WebPage exposes no callback for
        // WKDownload created via .download policy, so cancelling the
        // navigation + re-fetching ourselves is the only way to keep
        // visibility on the bytes.
        let decider = BrowserNavigationDecider(
            manager: downloads,
            cookieStore: cfg.websiteDataStore.httpCookieStore
        )
        let p = WebPage(configuration: cfg, navigationDecider: decider)

        // Make this WebView visible to Mac Safari's Web Inspector. Since
        // iOS 16.4, WKWebView (and by extension the iOS 26 WebPage) is
        // not inspectable by default — without this flag the page does
        // not appear under Develop → [device] in Safari, which makes
        // diagnosing chat-site key dispatch failures basically
        // impossible. Debug-only: never ship a production build that
        // exposes user pages to anyone with a USB cable.
        #if DEBUG
        p.isInspectable = true
        #endif

        return p
    }

    // MARK: navigation API

    func load(_ urlString: String) {
        let normalized = Self.normalizeURL(urlString)
        guard let url = URL(string: normalized) else { return }
        addressBarText = url.absoluteString
        consumeNavigationEvents(page.load(URLRequest(url: url)))
    }

    func goBack() {
        guard let p = _page,
              let item = p.backForwardList.backList.last else { return }
        consumeNavigationEvents(p.load(item))
    }

    func goForward() {
        guard let p = _page,
              let item = p.backForwardList.forwardList.first else { return }
        consumeNavigationEvents(p.load(item))
    }

    func reload() {
        guard let p = _page else { return }
        consumeNavigationEvents(p.reload())
    }

    func stop() {
        _page?.stopLoading()
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

// Same pattern as FocusBridge — separate object so the UCC's strong
// reference doesn't form a cycle with BrowserState. Receives one
// payload per intercepted blob:/data: download from the JS hook in
// InjectionScript.blobDownloadHook.
private final class BlobDownloadBridge: NSObject, WKScriptMessageHandler {
    var onMessage: (@MainActor ([String: Any]) -> Void)?

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        guard message.name == "vbDownload",
              let body = message.body as? [String: Any] else { return }
        Task { @MainActor in
            self.onMessage?(body)
        }
    }
}
