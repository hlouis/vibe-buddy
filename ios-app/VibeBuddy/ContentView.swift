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

    // Renamed off `Tab` so it doesn't shadow SwiftUI.Tab in the body.
    enum AppTab: Hashable { case transcript, browser, settings }

    @EnvironmentObject var router: TextRouter
    @State private var selected: AppTab = .transcript

    var body: some View {
        TabView(selection: $selected) {
            Tab("转写", systemImage: "waveform", value: AppTab.transcript) {
                TranscriptTabView()
            }
            Tab("浏览器", systemImage: "globe", value: AppTab.browser) {
                BrowserTabView()
            }
            Tab("设置", systemImage: "gearshape", value: AppTab.settings) {
                SettingsTabView()
            }
        }
        .onAppear { applyMode(selected) }
        .onChange(of: selected) { _, new in applyMode(new) }
    }

    private func applyMode(_ tab: AppTab) {
        // Browser tab → webview injection; everything else → pasteboard
        // only. Setting this synchronously means the very first ASR
        // partial after a tab switch already targets the right place.
        router.mode = (tab == .browser) ? .webview : .pasteboard
    }
}
