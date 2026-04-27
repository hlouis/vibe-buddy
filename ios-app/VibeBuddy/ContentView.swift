import SwiftUI
import VibeBuddyCore

// Three-tab root for the iOS / iPadOS app:
//
//   • 转写  : the original transcript view (live partials, history,
//             pasteboard copy buttons). TextRouter.mode = .pasteboard
//             while the user is here, so text only fans out to the
//             clipboard / in-app buffer.
//   • 浏览器: WKWebView with bookmarks + status bar. TextRouter.mode
//             = .webview, so each ASR partial also runs through the
//             WebViewInjector and lands in the focused page input.
//   • 设置  : Doubao credentials and bookmark management.
//
// Switching tabs is the only way to change modes — there's no separate
// toggle. The tab the user is looking at is the destination they get.
struct ContentView: View {

    enum Tab: Hashable { case transcript, browser, settings }

    @EnvironmentObject var router: TextRouter
    @State private var selected: Tab = .transcript

    var body: some View {
        TabView(selection: $selected) {
            TranscriptTabView()
                .tabItem { Label("转写", systemImage: "waveform") }
                .tag(Tab.transcript)

            BrowserTabView()
                .tabItem { Label("浏览器", systemImage: "globe") }
                .tag(Tab.browser)

            SettingsTabView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .onAppear { applyMode(selected) }
        // Single-arg onChange keeps us compatible with the iOS 16
        // deployment target; the iOS 17 two-arg overload is unavailable
        // on iOS 16 and we don't need the old-value here.
        .onChange(of: selected) { new in applyMode(new) }
    }

    private func applyMode(_ tab: Tab) {
        // Browser tab → webview injection; everything else → pasteboard
        // only. Setting this synchronously means the very first ASR
        // partial after a tab switch already targets the right place.
        router.mode = (tab == .browser) ? .webview : .pasteboard
    }
}
