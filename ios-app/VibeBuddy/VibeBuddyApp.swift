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
    @StateObject private var policies: PolicyStore
    @StateObject private var router: TextRouter
    @StateObject private var ble: BLEController
    // Owns the BLE↔mic switch + the iOS button-driven PTT trigger.
    // Constructed alongside `ble` so both share a single AudioStreamer
    // instance.
    @StateObject private var coord: AudioSourceCoordinator
    @Environment(\.scenePhase) private var scenePhase

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
        // Owned here so it can be passed into BrowserState (the
        // navigation decider needs the same instance to forward
        // intercepted download requests). BrowserTabView reads it via
        // browser.downloads, no separate environment entry needed.
        let dl = BrowserDownloadManager()
        let br = BrowserState(downloads: dl)
        let bm = BookmarkStore()
        let ps = PolicyStore()
        let rt = TextRouter(pasteboard: pb, webview: inj)

        // Each BtnA press resolves against the current store contents,
        // so user edits take effect immediately without a restart.
        // Captured weakly to avoid extending PolicyStore's lifetime
        // through the injector's closure.
        inj.policyProvider = { [weak ps] in
            ps?.items ?? SiteKeyPolicy.defaults
        }

        let bleObj = BLEController(textHandler: rt)
        let cd = AudioSourceCoordinator(ble: bleObj)

        _state = StateObject(wrappedValue: st)
        _pasteboard = StateObject(wrappedValue: pb)
        _injector = StateObject(wrappedValue: inj)
        _browser = State(wrappedValue: br)
        _bookmarks = StateObject(wrappedValue: bm)
        _policies = StateObject(wrappedValue: ps)
        _router = StateObject(wrappedValue: rt)
        _ble = StateObject(wrappedValue: bleObj)
        _coord = StateObject(wrappedValue: cd)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .environmentObject(pasteboard)
                .environmentObject(injector)
                .environment(browser)
                .environmentObject(bookmarks)
                .environmentObject(policies)
                .environmentObject(router)
                .environmentObject(ble)
                .environmentObject(coord)
                .onAppear {
                    ble.bind(state: state)
                    coord.bind(state: state)
                }
                // Mirror "where will my voice land" onto the StickS3.
                // Pasteboard mode -> the literal label; webview mode ->
                // the page title (falls back to host, then "Browser").
                // Re-fires on link-up via the mtu 0->N edge so the device
                // gets an initial value without the user changing modes.
                .onChange(of: currentTarget) { _, name in pushFrontApp(name) }
                .onChange(of: state.linkParams.mtu) { old, new in
                    if old == 0 && new > 0 { pushFrontApp(currentTarget) }
                }
                // iOS suspends URLSession in the background, so the ASR
                // WebSocket's receive loop never fires its close callback
                // and STTService.active stays stuck true. Force a teardown
                // on backgrounding so the next button press starts clean.
                // The coordinator additionally tears down the mic engine
                // (releases AVAudioSession) and re-arms on foreground so
                // the user can keep using the PTT button without a
                // restart-the-app dance.
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active {
                        ble.audio.cancelSession()
                        coord.handleAppBackgrounded()
                    } else {
                        coord.handleAppForegrounded()
                    }
                }
        }
    }

    private var currentTarget: String {
        switch router.mode {
        case .pasteboard: return "Pasteboard"
        case .webview:
            let t = browser.pageTitle
            if !t.isEmpty { return t }
            if let host = browser.currentURL?.host(), !host.isEmpty { return host }
            return "Browser"
        }
    }

    private func pushFrontApp(_ name: String) {
        guard !name.isEmpty else { return }
        let line = "{\"type\":\"front_app\",\"name\":\"\(jsonEscape(name))\"}\n"
        if let data = line.data(using: .utf8) {
            ble.write(data)
        }
    }
}

// Minimal JSON string escape — covers the only characters that can show
// up in a page title or mode label and would corrupt the wire format.
// We're not pulling in JSONEncoder for a single string field.
private func jsonEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s {
        switch ch {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:   out.append(ch)
        }
    }
    return out
}
