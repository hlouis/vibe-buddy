import SwiftUI
import WebKit
import VibeBuddyCore

// The "浏览器" tab — URL bar at top, WKWebView in the middle, toolbar +
// collapsible status bar at the bottom. Reads everything it needs from
// environment: BrowserState owns the webview, TextRouter owns the
// injection mode, AppState surfaces ASR partial text into the status
// bar.
//
// On iPad the same view is used as the always-on detail of the split
// shell, with `chrome = .toolbarOnly`. In that mode the bottom nav row
// and status bar are stripped — the sidebar already shows the status
// content, and back/forward swipe gestures replace the nav buttons.
//
// The view also signals the WebViewInjector to attach / detach when it
// appears / disappears so the injector only holds a webview reference
// while the user is actually looking at the browser tab.
struct BrowserTabView: View {

    // .full → original layout (iPhone tab).
    // .toolbarOnly → only the address bar + WebView; sidebar shell
    //   draws status & controls itself, and back/forward swipe replaces
    //   the dropped nav buttons.
    enum Chrome { case full, toolbarOnly }

    var chrome: Chrome = .full

    @EnvironmentObject var state: AppState
    // BrowserState is @Observable (wraps the iOS 26 WebPage); the
    // others are still ObservableObject + @Published.
    @Environment(BrowserState.self) var browser
    @EnvironmentObject var bookmarks: BookmarkStore
    @EnvironmentObject var router: TextRouter
    // Observed directly so @Published changes on the injector
    // (focusInfo, lastResult) trigger view updates. Reaching into
    // router.webview wouldn't, since SwiftUI only tracks one level.
    @EnvironmentObject var injector: WebViewInjector

    @State private var showBookmarks = false
    @AppStorage("statusBarExpanded") private var statusExpanded: Bool = true
    @AppStorage("lastBrowserURL") private var lastURL: String = "https://claude.ai/new"

    // .sheet(item:) wants Identifiable. URL isn't, and we want a fresh
    // sheet for every download anyway (so re-downloading the same path
    // re-pops the picker), so each presentation gets a UUID.
    private var shareItemBinding: Binding<ShareableDownload?> {
        Binding(
            get: {
                browser.downloads.pendingShare.map { ShareableDownload(url: $0) }
            },
            set: { newValue in
                if newValue == nil { browser.downloads.pendingShare = nil }
            }
        )
    }

    // Safari-style auto-collapse on iPhone (.full chrome). After a page
    // finishes loading we shrink the top URL row and merge the bottom
    // nav + status rows into a thin strip; tapping either strip — or
    // anything that demands user attention (address focus, fresh ASR
    // partial text) — pops the full chrome back.
    @State private var chromeCollapsed: Bool = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        Group {
            if chrome == .full {
                // Skeleton: WebView size is fixed (always == collapsed
                // layout). The expanded chrome floats on top as overlays
                // so the WebView viewport never resizes — fixed/sticky
                // CSS, 100vh, scroll position all stay stable when the
                // user toggles chrome.
                VStack(spacing: 0) {
                    collapsedTopStrip
                    webContent
                    collapsedBottomStrip
                }
                .overlay(alignment: .top) {
                    if !chromeCollapsed {
                        addressBar
                            // Soft drop shadow downward — sells the
                            // "floating above webview" feel without
                            // looking heavy. y:2 so the shadow only
                            // shows on the bottom edge where chrome
                            // meets the page.
                            .shadow(color: .black.opacity(0.10), radius: 6, x: 0, y: 2)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .overlay(alignment: .bottom) {
                    if !chromeCollapsed {
                        VStack(spacing: 0) {
                            navToolbar
                            BrowserStatusBar(expanded: $statusExpanded)
                        }
                        // Mirror of the top shadow, cast upward.
                        .shadow(color: .black.opacity(0.10), radius: 6, x: 0, y: -2)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.22), value: chromeCollapsed)
            } else {
                // toolbarOnly: no in-body address bar — fold it into
                // the parent NavigationSplitView's detail toolbar so
                // we don't double up on chrome rows.
                webContent
                    .toolbar { addressToolbar }
                    .toolbarBackground(.thinMaterial, for: .navigationBar)
            }
        }
        // Loading edge true→false: page settled, fold the chrome away.
        .onChange(of: browser.isLoading) { old, new in
            if old && !new && chrome == .full {
                chromeCollapsed = true
            }
        }
        // Address bar focus → user is typing a URL, must show full chrome.
        .onChange(of: addressFocused) { _, focused in
            if focused { chromeCollapsed = false }
        }
        // Live ASR partial: user is dictating, status MUST be visible
        // so they can see what got transcribed. Never break userspace.
        .onChange(of: state.partialText) { _, txt in
            if !txt.isEmpty { chromeCollapsed = false }
        }
        .onChange(of: state.asrError) { _, err in
            if !err.isEmpty { chromeCollapsed = false }
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarksSheet { url in
                browser.load(url)
                lastURL = url
                showBookmarks = false
            }
        }
        // Pop a share sheet whenever a download finishes. Driven off
        // BrowserState.downloads.pendingShare — the manager sets it on
        // success, this binding clears it on dismiss. We wrap the URL
        // in an Identifiable shim so .sheet(item:) keys correctly when
        // the same path is re-presented after a second download.
        .sheet(item: shareItemBinding) { wrapped in
            DownloadShareSheet(url: wrapped.url)
        }
        .onAppear {
            // Activate the injector against the live WebPage only
            // while the browser tab is visible. Other tabs don't get
            // text injected — they wouldn't see it anyway.
            injector.attach(browser.page)
            browser.onFocusMessage = { [weak injector] descriptor, isInjectable in
                injector?.updateFocus(descriptor: descriptor, injectable: isInjectable)
            }
            // First-launch convenience: bring up the last URL we
            // navigated to (or the default Claude URL if none).
            if browser.currentURL == nil {
                browser.load(lastURL)
            }
        }
        .onDisappear {
            injector.detach()
            if let url = browser.currentURL?.absoluteString { lastURL = url }
        }
    }

    // MARK: web content (shared by both chrome modes)

    private var webContent: some View {
        ZStack(alignment: .top) {
            // SwiftUI-native WebView (iOS 26+). Replaces the old
            // UIViewRepresentable bridge — no more touch-event crashes
            // inside UIGestureRecognizer because we're not wedging a
            // UIKit view into SwiftUI's hit-test chain any more, the
            // system owns the integration end-to-end.
            WebView(browser.page)
                .ignoresSafeArea(edges: .horizontal)
                .webViewBackForwardNavigationGestures(.enabled)
            if browser.isLoading {
                ProgressView(value: browser.loadingProgress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
            }
        }
    }

    // MARK: collapsed strips (iPhone .full only — Safari-style auto-hide)

    // Replaces `addressBar` when chrome is collapsed. Single short row
    // showing only lock + host. Tap anywhere to expand the full chrome.
    private var collapsedTopStrip: some View {
        HStack(spacing: 6) {
            Image(systemName: browser.currentURL?.scheme == "https" ? "lock.fill" : "globe")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(collapsedHostText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 22)
        .background(.thinMaterial)
        .contentShape(Rectangle())
        .onTapGesture { chromeCollapsed = false }
        .accessibilityLabel("展开浏览器工具栏")
        .accessibilityAddTraits(.isButton)
    }

    // Replaces `navToolbar` + `BrowserStatusBar` when collapsed.
    // Shows only the two indicator dots (link + focus) + a chevron hint.
    private var collapsedBottomStrip: some View {
        HStack(spacing: 8) {
            Circle().fill(collapsedLinkColor).frame(width: 6, height: 6)
            Circle().fill(collapsedFocusColor).frame(width: 6, height: 6)
            Text(collapsedFocusText)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Image(systemName: "chevron.up")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: 22)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
        .contentShape(Rectangle())
        .onTapGesture { chromeCollapsed = false }
        .accessibilityLabel("展开浏览器状态栏")
        .accessibilityAddTraits(.isButton)
    }

    private var collapsedHostText: String {
        if let host = browser.currentURL?.host, !host.isEmpty { return host }
        return browser.addressBarText.isEmpty ? "—" : browser.addressBarText
    }

    private var collapsedLinkColor: Color {
        switch state.link {
        case .connected:             return .green
        case .connecting, .scanning: return .yellow
        case .failed:                return .red
        case .idle:                  return .gray
        }
    }

    private var collapsedFocusColor: Color {
        injector.focusInjectable ? .green : .orange
    }

    private var collapsedFocusText: String {
        injector.focusInfo.isEmpty ? "未识别焦点" : injector.focusInfo
    }

    // MARK: address bar (iPhone .full layout — bar at the top of the VStack)

    private var addressBar: some View {
        // @Bindable shim is the @Observable-era replacement for the old
        // ObservableObject `$envObject.field` syntax — needed because
        // BrowserState moved off @Published.
        @Bindable var browser = browser
        return HStack(spacing: 8) {
            Button {
                showBookmarks = true
            } label: {
                Image(systemName: "bookmark")
                    .imageScale(.medium)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                Image(systemName: browser.currentURL?.scheme == "https" ? "lock.fill" : "globe")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("URL 或关键词", text: $browser.addressBarText)
                    .focused($addressFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit {
                        browser.load(browser.addressBarText)
                    }
                if browser.isLoading {
                    Button { browser.stop() } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button { browser.reload() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.gray.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }

    // MARK: address toolbar (iPad .toolbarOnly — slots into the
    // NavigationSplitView's detail navigation bar so the in-body
    // address row disappears entirely).

    @ToolbarContentBuilder
    private var addressToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showBookmarks = true
            } label: {
                Image(systemName: "bookmark")
            }
        }
        ToolbarItem(placement: .principal) {
            urlField
        }
        ToolbarItem(placement: .topBarTrailing) {
            if browser.isLoading {
                Button { browser.stop() } label: {
                    Image(systemName: "xmark")
                }
            } else {
                Button { browser.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }

    private var urlField: some View {
        @Bindable var browser = browser
        return HStack(spacing: 6) {
            Image(systemName: browser.currentURL?.scheme == "https" ? "lock.fill" : "globe")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("URL 或关键词", text: $browser.addressBarText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit { browser.load(browser.addressBarText) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.gray.opacity(0.12), in: Capsule())
        .frame(minWidth: 320, idealWidth: 640, maxWidth: 900)
    }

    // MARK: nav toolbar (iPhone .full only)

    private var navToolbar: some View {
        HStack(spacing: 4) {
            Button { browser.goBack() } label: {
                Image(systemName: "chevron.backward").frame(width: 44, height: 36)
            }
            .disabled(!browser.canGoBack)

            Button { browser.goForward() } label: {
                Image(systemName: "chevron.forward").frame(width: 44, height: 36)
            }
            .disabled(!browser.canGoForward)

            Spacer()

            BrowserFocusBadge()

            Spacer()

            BrowserInjectionButtons()

            // Safari-style collapse trigger. Replaces the DEBUG-only
            // bolt button that used to sit here. Lives in navToolbar
            // (not BrowserInjectionButtons) because the latter is
            // reused by the iPad sidebar where chrome collapsing
            // doesn't apply.
            Button {
                addressFocused = false
                chromeCollapsed = true
            } label: {
                Image(systemName: "rectangle.compress.vertical")
                    .frame(width: 44, height: 36)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("收起浏览器工具栏")
        }
        .font(.body.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.thinMaterial)
    }
}

// MARK: - Shared chrome subviews (used by iPhone navToolbar + iPad sidebar)

// Focus state pill ("未识别焦点" / "TEXTAREA#input" + colored dot).
struct BrowserFocusBadge: View {
    @EnvironmentObject var injector: WebViewInjector

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(badgeColor).frame(width: 7, height: 7)
            Text(badgeText)
                .font(.caption.monospaced())
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.gray.opacity(0.10), in: Capsule())
    }

    private var badgeColor: Color {
        injector.focusInjectable ? .green : .orange
    }

    private var badgeText: String {
        injector.focusInfo.isEmpty ? "未识别焦点" : injector.focusInfo
    }
}

// Paste-clipboard / toggle-keyboard / DEBUG-fire-Enter button row.
// Reused unchanged in iPhone navToolbar and iPad sidebar footer.
struct BrowserInjectionButtons: View {
    @EnvironmentObject var injector: WebViewInjector

    var body: some View {
        HStack(spacing: 4) {
            // Quick "drop current pasteboard into the page" — useful
            // when auto-injection lost focus and you want to paste the
            // latest transcript without leaving the app.
            Button {
                let s = UIPasteboard.general.string ?? ""
                if !s.isEmpty {
                    injector.update(to: s)
                }
            } label: {
                Image(systemName: "doc.on.clipboard")
                    .frame(width: 44, height: 36)
                    .foregroundStyle(.secondary)
            }

            // Soft keyboard toggle. Default suppressed (focus does not
            // pop the keyboard); tap to summon it for the focused field.
            Button {
                injector.toggleKeyboardSuppressed()
            } label: {
                Image(systemName: injector.keyboardSuppressed
                      ? "keyboard.chevron.compact.down"
                      : "keyboard.fill")
                    .frame(width: 44, height: 36)
                    .foregroundStyle(injector.keyboardSuppressed ? .secondary : Color.accentColor)
            }

        }
    }
}

// MARK: - Status bar (collapsible)
//
// Promoted from the file-private `StatusBar` so the iPad shell can drop
// the same view into its sidebar footer.
struct BrowserStatusBar: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var router: TextRouter
    @EnvironmentObject var injector: WebViewInjector
    @Environment(BrowserState.self) var browser
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle().fill(linkColor).frame(width: 8, height: 8)
                Text(linkText).font(.caption.bold())
                Text("·").foregroundStyle(.tertiary)
                Text(injectionLabel)
                    .font(.caption)
                    .foregroundColor(injectionColor)
                    .lineLimit(1)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.plain)
            }
            if expanded {
                let live = !state.partialText.isEmpty ? state.partialText
                         : !state.finalText.isEmpty   ? state.finalText
                         : ""
                if !live.isEmpty {
                    Text(live)
                        .font(.callout)
                        .foregroundColor(state.partialText.isEmpty ? .primary : .blue)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("（按住设备 A 按钮开始说话）")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if !state.asrError.isEmpty {
                    Text("ASR 错误：\(state.asrError)")
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
                // Latest download — single row, suppressed when no
                // downloads have ever been attempted. Tapping a
                // finished one re-pops the share sheet so the user can
                // save it again after closing without re-downloading.
                if let item = browser.downloads.latest {
                    DownloadStatusRow(item: item) {
                        if case .finished(let url) = item.state {
                            browser.downloads.pendingShare = url
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private var linkColor: Color {
        switch state.link {
        case .connected:             return .green
        case .connecting, .scanning: return .yellow
        case .failed:                return .red
        case .idle:                  return .gray
        }
    }

    private var linkText: String {
        switch state.link {
        case .idle:              return "蓝牙启动中"
        case .scanning:          return "扫描中"
        case .connecting(let n): return "连接 \(n)"
        case .connected(let n):  return n
        case .failed(let s):     return "失败:\(s)"
        }
    }

    private var injectionLabel: String {
        switch injector.lastResult {
        case .idle:              return router.mode == .webview ? "等待输入" : "剪贴板模式"
        case .ok(let mode, let f): return "已注入 \(f) (\(mode))"
        case .noFocus:           return "无焦点 · 已存剪贴板"
        case .unsupported(let f): return "不支持 \(f) · 已存剪贴板"
        case .exception(let e):  return "注入异常: \(e.prefix(28))"
        }
    }

    private var injectionColor: Color {
        switch injector.lastResult {
        case .ok:        return .green
        case .idle:      return .secondary
        default:         return .orange
        }
    }
}

// MARK: - Bookmarks sheet

struct BookmarksSheet: View {
    @EnvironmentObject var bookmarks: BookmarkStore
    @Environment(\.dismiss) private var dismiss
    let onPick: (String) -> Void

    @State private var showAddSheet = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 16)], spacing: 16) {
                    ForEach(bookmarks.items) { bm in
                        Button {
                            onPick(bm.url)
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: bm.symbol)
                                    .font(.system(size: 28))
                                    .frame(width: 56, height: 56)
                                    .background(.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                                Text(bm.name).font(.callout).foregroundStyle(.primary)
                                Text(host(bm.url)).font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                bookmarks.remove(bm.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("书签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddBookmarkSheet { name, url in
                    bookmarks.add(name: name, url: url)
                }
            }
        }
    }

    private func host(_ urlString: String) -> String {
        URL(string: urlString)?.host ?? urlString
    }
}

private struct AddBookmarkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var url: String = ""
    let onSave: (String, String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") { TextField("例如：通义", text: $name) }
                Section("地址") {
                    TextField("https://...", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
            }
            .navigationTitle("添加书签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(name, BrowserState.normalizeURL(url))
                        dismiss()
                    }
                    .disabled(name.isEmpty || url.isEmpty)
                }
            }
        }
    }
}

// MARK: - Download UI

// Identifiable shim so .sheet(item:) re-presents on every download.
// id is generated per wrapping, not derived from URL, so saving the
// same file twice still triggers two distinct sheet presentations.
private struct ShareableDownload: Identifiable {
    let id = UUID()
    let url: URL
}

// One-row download status (shown inside BrowserStatusBar's expanded
// area). Active downloads show a spinner; failures show the reason in
// orange; finished downloads are tappable to re-open the share sheet.
struct DownloadStatusRow: View {
    let item: BrowserDownloadManager.Item
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            icon
            Text(item.filename)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(stateText)
                .font(.caption2)
                .foregroundStyle(stateColor)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    @ViewBuilder private var icon: some View {
        switch item.state {
        case .downloading:
            ProgressView().controlSize(.mini)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        }
    }

    private var stateText: String {
        switch item.state {
        case .downloading:        return "下载中"
        case .finished:           return "点击保存"
        case .failed(let reason): return reason
        }
    }

    private var stateColor: Color {
        switch item.state {
        case .downloading: return .secondary
        case .finished:    return .blue
        case .failed:      return .orange
        }
    }
}

// Plain UIActivityViewController bridge. The "笨但稳" save path: hand
// the temp-file URL to the system share sheet and let the user pick
// where it lands — Files, AirDrop, mail, whatever. We don't write to
// the app's documents dir at all, which means no Info.plist work
// (UIFileSharingEnabled / LSSupportsOpeningDocumentsInPlace) is
// required to ship this.
struct DownloadShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController,
                                context: Context) {}
}
