import SwiftUI
import VibeBuddyCore

@main
struct VibeBuddyApp: App {
    @StateObject private var state: AppState
    @StateObject private var pasteboard: PasteboardHandler
    @StateObject private var injector: WebViewInjector
    // BrowserState is @Observable (wraps the iOS 26 WebPage), so it
    // takes @State for ownership and propagates via the new
    // .environment(_:) modifier — not @StateObject / .environmentObject.
    @State private var browser: BrowserState
    @StateObject private var bookmarks: BookmarkStore
    @StateObject private var router: TextRouter
    @StateObject private var ble: BLEController

    @MainActor
    init() {
        // Build the dependency graph in one place. The router gets a
        // strong reference to both the pasteboard handler and the
        // WebView injector; BLEController only sees the router via the
        // TextHandler protocol so the shared package stays unaware of
        // any iOS-specific routing.
        let st = AppState()
        let pb = PasteboardHandler()
        let inj = WebViewInjector()
        let br = BrowserState()
        let bm = BookmarkStore()
        let rt = TextRouter(pasteboard: pb, webview: inj)

        _state = StateObject(wrappedValue: st)
        _pasteboard = StateObject(wrappedValue: pb)
        _injector = StateObject(wrappedValue: inj)
        _browser = State(wrappedValue: br)
        _bookmarks = StateObject(wrappedValue: bm)
        _router = StateObject(wrappedValue: rt)
        _ble = StateObject(wrappedValue: BLEController(textHandler: rt))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .environmentObject(pasteboard)
                .environmentObject(injector)
                .environment(browser)
                .environmentObject(bookmarks)
                .environmentObject(router)
                .environmentObject(ble)
                .onAppear { ble.bind(state: state) }
        }
    }
}
