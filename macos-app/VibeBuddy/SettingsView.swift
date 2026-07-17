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
    @EnvironmentObject var ble: BLEController

    var body: some View {
        TabView {
            DoubaoSettings()
                .environmentObject(state)
                .tabItem { Label("Doubao API", systemImage: "key") }
            DeviceSettings()
                .environmentObject(state)
                .environmentObject(ble)
                .tabItem { Label("设备", systemImage: "dot.radiowaves.left.and.right") }
        }
        .frame(width: 520, height: 360)
    }
}

// Device pairing. Scanning here is deliberately tied to the tab being
// visible (onAppear/onDisappear): it runs with allowDuplicates so RSSI
// stays live, which is too expensive to leave on permanently.
private struct DeviceSettings: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var ble: BLEController

    private var connectedID: String? {
        guard case .connected(let name) = state.link else { return nil }
        return BLEController.deviceID(fromName: name)
    }

    private var unpaired: [AppState.DiscoveredDevice] {
        state.discoveredDevices.filter { !state.pairedDeviceIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.pairedDeviceIDs.isEmpty {
                Label("未配对：将连接第一个搜索到的 VibeBuddy 设备。配对后只连白名单内的设备。",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("已配对").font(.headline)
            if state.pairedDeviceIDs.isEmpty {
                Text("（无）").foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(state.pairedDeviceIDs, id: \.self) { id in
                    HStack {
                        Circle()
                            .fill(connectedID == id ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 8, height: 8)
                        Text("VibeBuddy-\(id)").font(.system(.body, design: .monospaced))
                        if connectedID == id {
                            Text("已连接").font(.caption).foregroundStyle(.green)
                        }
                        Spacer()
                        Button("取消配对") { ble.unpair(deviceID: id) }
                            .controlSize(.small)
                    }
                }
            }

            Divider()

            HStack {
                Text("附近设备").font(.headline)
                if state.discovering { ProgressView().controlSize(.small) }
            }
            if unpaired.isEmpty {
                Text(state.discovering ? "搜索中…" : "未搜索到未配对的设备")
                    .foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(unpaired) { dev in
                    HStack {
                        Text(dev.name).font(.system(.body, design: .monospaced))
                        Text("\(dev.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("配对") { ble.pair(deviceID: dev.id) }
                            .controlSize(.small)
                    }
                }
            }
            Spacer()
        }
        .padding(20)
        .onAppear { ble.startDiscovery() }
        .onDisappear { ble.stopDiscovery() }
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
