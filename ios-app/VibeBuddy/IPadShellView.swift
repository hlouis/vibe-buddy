import SwiftUI
import VibeBuddyCore

// iPad shell. The browser is the always-on background; the sidebar is
// the foreground tool drawer (转写 / 设置 tabs + a global status &
// injection-controls footer).
//
// Compared to ContentView's iPhone TabView path:
//   • The browser is no longer one of three peer tabs — it's the
//     always-resident detail. router.mode is therefore pinned to
//     .webview the entire time the iPad shell is on screen, so ASR text
//     always tries the WebView first (and falls through to the
//     pasteboard if no focus, just like before).
//   • Connection / injection / live-partial status moves out of the
//     browser bottom strip into the sidebar footer where it stays
//     visible regardless of which sidebar tab the user is on.
struct IPadShellView: View {

    enum SidebarTab: Hashable { case transcript, settings }

    @EnvironmentObject var router: TextRouter
    @State private var sidebarTab: SidebarTab = .transcript
    @State private var splitVisibility: NavigationSplitViewVisibility = .doubleColumn
    @AppStorage("statusBarExpanded") private var statusExpanded: Bool = true

    var body: some View {
        NavigationSplitView(columnVisibility: $splitVisibility) {
            sidebarColumn
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 380)
        } detail: {
            // NavigationStack here so BrowserTabView(.toolbarOnly) can
            // hang its address bar off `.toolbar` — the navigation bar
            // that the system already draws above the detail (with the
            // sidebar-toggle button) becomes our address row, and we
            // don't draw a second strip below it.
            NavigationStack {
                BrowserTabView(chrome: .toolbarOnly)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .navigationSplitViewStyle(.balanced)
        // Browser is always present in detail → injection mode is the
        // only mode that makes sense. Pin it on appear and never flip.
        .onAppear { router.mode = .webview }
    }

    // MARK: sidebar

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            TabView(selection: $sidebarTab) {
                Tab("转写", systemImage: "waveform", value: SidebarTab.transcript) {
                    TranscriptTabView()
                }
                Tab("设置", systemImage: "gearshape", value: SidebarTab.settings) {
                    SettingsTabView()
                }
            }
            Divider()
            sidebarFooter
        }
    }

    // Status row (link / injection / live partial) + injection
    // controls (focus badge + paste / kb / debug). Both are global
    // across sidebar tabs — the user can be editing settings and still
    // watch the link state without flipping back.
    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            BrowserStatusBar(expanded: $statusExpanded)
            HStack(spacing: 6) {
                BrowserFocusBadge()
                Spacer(minLength: 4)
                BrowserInjectionButtons()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.thinMaterial)
        }
    }
}
