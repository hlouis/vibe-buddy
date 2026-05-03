import SwiftUI
import VibeBuddyCore

// Root layout dispatcher.
//
// • compact (iPhone)  → bottom TabView { 转写 | 浏览器 | 设置 }
//                       — original three-peer layout. router.mode flips
//                       on tab change so the transcript / settings tabs
//                       fall back to pasteboard and only the browser
//                       tab routes to the WebView injector.
//
// • regular (iPad)    → IPadShellView, NavigationSplitView shell with
//                       the WebView always live in the detail column
//                       and 转写 / 设置 sharing the sidebar. router.mode
//                       is pinned to .webview the whole time the iPad
//                       shell is on screen (the browser is always
//                       visible, so the only sensible destination for
//                       ASR text is the page).
struct ContentView: View {

    enum AppTab: Hashable { case transcript, browser, settings }

    @EnvironmentObject var router: TextRouter
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var selected: AppTab = .transcript

    var body: some View {
        if hSize == .regular {
            IPadShellView()
        } else {
            tabLayout
                .onAppear { applyMode(selected) }
                .onChange(of: selected) { _, new in applyMode(new) }
        }
    }

    private var tabLayout: some View {
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
    }

    private func applyMode(_ tab: AppTab) {
        // iPhone path: browser tab → webview injection; everything else
        // → pasteboard only. iPad path pins .webview itself, so this
        // logic is compact-only.
        router.mode = (tab == .browser) ? .webview : .pasteboard
    }
}
