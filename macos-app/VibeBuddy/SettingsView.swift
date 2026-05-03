import SwiftUI
import AppKit
import VibeBuddyCore

// Standard macOS Settings window (Cmd+,). Single tab for now: Doubao
// API credentials. Writes ~/.config/vibe-buddy/config.json — the same
// file the app already reads on every PTT session start, so changes
// take effect on the next recording without an app restart.
//
// Deliberately narrow scope: this is for static configuration. Live
// state (audio source, permissions, BLE link) lives in the main
// window because the user reaches for those mid-task, not Cmd+,.
struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView {
            DoubaoSettings()
                .environmentObject(state)
                .tabItem { Label("Doubao API", systemImage: "key") }
        }
        .frame(width: 520, height: 360)
    }
}

private struct DoubaoSettings: View {
    @EnvironmentObject var state: AppState

    // Form-local state. Loaded from disk on appear; not bound to
    // Config.load() return so the user can edit freely without each
    // keystroke triggering a re-read.
    @State private var appID: String = ""
    @State private var accessToken: String = ""
    @State private var resourceID: String = ""
    @State private var revealToken: Bool = false
    @State private var feedback: Feedback = .none
    @State private var showDeleteConfirm: Bool = false

    enum Feedback: Equatable {
        case none
        case saved
        case failed(String)
    }

    private var configPath: String {
        Config.sourceDescription
    }

    private var canSave: Bool {
        !appID.trimmed.isEmpty && !accessToken.trimmed.isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("App ID", text: $appID, prompt: Text("X-Api-App-Key"))
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 6) {
                    Group {
                        if revealToken {
                            TextField("Access Token", text: $accessToken,
                                      prompt: Text("X-Api-Access-Key"))
                        } else {
                            SecureField("Access Token", text: $accessToken,
                                        prompt: Text("X-Api-Access-Key"))
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    Button {
                        revealToken.toggle()
                    } label: {
                        Image(systemName: revealToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(revealToken ? "隐藏" : "显示")
                }

                TextField("Resource ID", text: $resourceID,
                          prompt: Text(Config.defaultResourceID))
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("凭证").font(.headline)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Resource ID 留空则使用默认值 \(Config.defaultResourceID)")
                        .font(.caption).foregroundColor(.secondary)
                    Text("配置文件：\(configPath)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section {
                HStack(spacing: 10) {
                    Button("保存") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)

                    Button("从磁盘重新载入") { reload() }

                    Spacer()

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Text("删除配置")
                    }
                    .disabled(state.configMissing)
                }

                feedbackRow
            }
        }
        .formStyle(.grouped)
        .onAppear { reload() }
        .confirmationDialog(
            "删除配置文件？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { deleteConfig() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从磁盘移除 \(configPath)。下次录音前需要重新填写。")
        }
    }

    @ViewBuilder private var feedbackRow: some View {
        switch feedback {
        case .none:
            EmptyView()
        case .saved:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text("已保存 — 下次按 PTT 录音时生效。")
                    .font(.caption).foregroundColor(.secondary)
            }
        case .failed(let msg):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "xmark.octagon.fill").foregroundColor(.red)
                Text(msg)
                    .font(.caption).foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: actions

    private func reload() {
        if let cfg = Config.load() {
            appID = cfg.appID
            accessToken = cfg.accessToken
            resourceID = cfg.resourceID
        } else {
            appID = ""
            accessToken = ""
            resourceID = ""
        }
        feedback = .none
        state.configMissing = (Config.load() == nil)
    }

    private func save() {
        let rid = resourceID.trimmed.isEmpty ? Config.defaultResourceID : resourceID.trimmed
        do {
            try Config.save(
                appID: appID.trimmed,
                accessToken: accessToken.trimmed,
                resourceID: rid
            )
            resourceID = rid
            feedback = .saved
            state.configMissing = (Config.load() == nil)
        } catch {
            feedback = .failed("保存失败：\(error.localizedDescription)")
        }
    }

    private func deleteConfig() {
        do {
            try Config.clear()
            reload()
            feedback = .saved   // empty form is the success signal
            state.configMissing = true
        } catch {
            feedback = .failed("删除失败：\(error.localizedDescription)")
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
