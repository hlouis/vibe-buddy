import SwiftUI
import WebKit
import VibeBuddyCore

// The "浏览器" tab — URL bar at top, WKWebView in the middle, toolbar +
// collapsible status bar at the bottom. Reads everything it needs from
// environment: BrowserState owns the webview, TextRouter owns the
// injection mode, AppState surfaces ASR partial text into the status
// bar.
//
// The view also signals the WebViewInjector to attach / detach when it
// appears / disappears so the injector only holds a webview reference
// while the user is actually looking at the browser tab.
struct BrowserTabView: View {
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

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            ZStack(alignment: .top) {
                // SwiftUI-native WebView (iOS 26+). Replaces the old
                // UIViewRepresentable bridge — no more touch-event
                // crashes inside UIGestureRecognizer because we're not
                // wedging a UIKit view into SwiftUI's hit-test chain
                // any more, the system owns the integration end-to-end.
                WebView(browser.page)
                    .ignoresSafeArea(edges: .horizontal)
                if browser.isLoading {
                    ProgressView(value: browser.loadingProgress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                }
            }
            navToolbar
            StatusBar(expanded: $statusExpanded)
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarksSheet { url in
                browser.load(url)
                lastURL = url
                showBookmarks = false
            }
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

    // MARK: address bar

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

    // MARK: nav toolbar

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

            modeBadge

            Spacer()

            // Quick "drop current pasteboard into the page" — useful
            // when the auto-injection lost focus and you want to paste
            // the latest transcript without leaving the app.
            Button {
                let s = UIPasteboard.general.string ?? ""
                if !s.isEmpty {
                    injector.update(to: s)
                }
            } label: {
                Image(systemName: "doc.on.clipboard").frame(width: 44, height: 36)
            }

            Button {
                showBookmarks = true
            } label: {
                Image(systemName: "square.grid.2x2").frame(width: 44, height: 36)
            }
        }
        .font(.body.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.thinMaterial)
    }

    private var modeBadge: some View {
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
        if injector.focusInjectable { return .green }
        return .orange
    }

    private var badgeText: String {
        if injector.focusInfo.isEmpty { return "未识别焦点" }
        return injector.focusInfo
    }
}

// MARK: - Status bar (collapsible)

private struct StatusBar: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var router: TextRouter
    @EnvironmentObject var injector: WebViewInjector
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

private struct BookmarksSheet: View {
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
