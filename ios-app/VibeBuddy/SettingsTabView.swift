import SwiftUI
import VibeBuddyCore

// "设置" tab — credentials + bookmarks. Lives at the same level as
// the transcript and browser tabs (no longer a modal sheet) so users
// can flip back and forth while diagnosing a connection or testing
// against a new bookmark URL.
struct SettingsTabView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var bookmarks: BookmarkStore

    @State private var appID: String = ""
    @State private var accessToken: String = ""
    @State private var resourceID: String = Config.defaultResourceID
    @State private var saved: Bool = false

    @State private var newBookmarkName: String = ""
    @State private var newBookmarkURL: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("App ID", text: $appID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Access Token", text: $accessToken)
                    TextField("Resource ID", text: $resourceID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        save()
                    } label: {
                        if saved {
                            Label("已保存", systemImage: "checkmark")
                        } else {
                            Label("保存凭证", systemImage: "tray.and.arrow.down")
                        }
                    }
                    .disabled(appID.isEmpty || accessToken.isEmpty)
                } header: {
                    Text("Doubao 凭证")
                } footer: {
                    Text("在火山引擎控制台 · 语音技术 · 大模型流式语音识别 中获取。")
                }

                Section("书签") {
                    ForEach(bookmarks.items) { bm in
                        HStack {
                            Image(systemName: bm.symbol).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bm.name)
                                Text(bm.url).font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { bookmarks.items[$0].id }.forEach { bookmarks.remove($0) }
                    }
                    HStack {
                        TextField("名称", text: $newBookmarkName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("https://...", text: $newBookmarkURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Button {
                            bookmarks.add(name: newBookmarkName,
                                          url: BrowserState.normalizeURL(newBookmarkURL))
                            newBookmarkName = ""
                            newBookmarkURL = ""
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(newBookmarkName.isEmpty || newBookmarkURL.isEmpty)
                    }
                    Button("恢复预设") {
                        bookmarks.resetToPresets()
                    }
                    .foregroundColor(.accentColor)
                }

                Section("关于") {
                    LabeledContent("版本", value: appVersion)
                    LabeledContent("浏览器模式") {
                        Text("WKWebView · 默认 cookie 存储")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: load)
        }
    }

    private func load() {
        if let cfg = Config.load() {
            appID = cfg.appID
            accessToken = cfg.accessToken
            resourceID = cfg.resourceID
        }
    }

    private func save() {
        let id = appID.trimmingCharacters(in: .whitespaces)
        let token = accessToken.trimmingCharacters(in: .whitespaces)
        let res = resourceID.trimmingCharacters(in: .whitespaces)
        Config.save(
            appID: id,
            accessToken: token,
            resourceID: res.isEmpty ? Config.defaultResourceID : res
        )
        state.configMissing = (Config.load() == nil)
        saved = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            saved = false
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
