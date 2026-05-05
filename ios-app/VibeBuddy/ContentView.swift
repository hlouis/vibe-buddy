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
//
// Floating PTT orb (mic mode only):
//   • iPhone: shown on the 浏览器 tab only — 转写 already has the big
//     in-line MicPTTButton, and 设置 was explicitly excluded by user
//     request (avoids accidental presses while editing API tokens).
//   • iPad: handled inside IPadShellView based on sidebar visibility.
struct ContentView: View {

    enum AppTab: Hashable { case transcript, browser, settings }

    @EnvironmentObject var router: TextRouter
    @EnvironmentObject var state: AppState
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var selected: AppTab = .transcript

    var body: some View {
        if hSize == .regular {
            IPadShellView()
        } else {
            ZStack(alignment: .bottomTrailing) {
                tabLayout
                    .onAppear { applyMode(selected) }
                    .onChange(of: selected) { _, new in applyMode(new) }

                // Top toasts: error first, transcript below it. Both
                // use the same visibility rule as the orb — they're
                // only there to surface state that's already visible
                // inline on the transcript tab.
                if shouldShowOverlays {
                    VStack(spacing: 4) {
                        ErrorBanner()
                        TranscriptBanner()
                        Spacer()
                    }
                }

                // Orb floats above the TabView. bottomInset clears the
                // TabBar (~49 pt) + home-indicator inset; FloatingPTTOrb
                // itself uses .ignoresSafeArea(.keyboard) so it stays
                // visible when a form field opens the keyboard.
                if shouldShowOrb {
                    FloatingPTTOrb(bottomInset: 70)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.78),
                       value: shouldShowOrb)
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

    // The orb is shown on the browser tab only — transcript already
    // has the large in-line button, and the user explicitly asked to
    // suppress it on the settings tab to avoid mishits while typing
    // API credentials.
    private var shouldShowOrb: Bool {
        guard state.audioSource == .mic else { return false }
        guard state.micAuth == .granted else { return false }
        guard state.hotkeyEnabled else { return false }
        return selected == .browser
    }

    // Overlay toasts (transcript live preview + error banner) use a
    // looser rule than the orb: they're useful in BLE mode too (to
    // see what the device is transcribing while you're in the
    // browser) and don't need the granted-permission preconditions.
    // Suppressed on the transcript tab where the same content is
    // already inline, and on settings to keep the form clean.
    private var shouldShowOverlays: Bool {
        selected == .browser
    }

    private func applyMode(_ tab: AppTab) {
        // iPhone path: browser tab → webview injection; everything else
        // → pasteboard only. iPad path pins .webview itself, so this
        // logic is compact-only.
        router.mode = (tab == .browser) ? .webview : .pasteboard
    }
}
