import SwiftUI
import VibeBuddyCore

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var ble: BLEController
    @EnvironmentObject var pasteboard: PasteboardHandler

    @State private var showSettings: Bool = false
    @State private var showCopiedToast: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if state.configMissing {
                        configMissingCard
                    }
                    statusCard
                    if case .connected = state.link { linkParamsRow }
                    transcriptCard
                    historyCard
                    debugCard
                }
                .padding()
            }
            .navigationTitle("Vibe Buddy")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(onSaved: {
                    state.configMissing = (Config.load() == nil)
                })
            }
            .overlay(alignment: .top) {
                if showCopiedToast {
                    Text("已复制到剪贴板")
                        .font(.callout)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: status

    private var configMissingCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Doubao 凭证未配置").font(.callout).bold()
                Text("点击右上角齿轮，填入 App ID 与 Access Token。")
                    .font(.caption).foregroundColor(.secondary)
                Button("打开设置") { showSettings = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Spacer()
        }
        .padding()
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            Circle().fill(statusColor).frame(width: 12, height: 12)
            Text(statusText).font(.body)
            Spacer()
            Text("\(state.totalSessions) 段")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding()
        .background(.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusColor: Color {
        switch state.link {
        case .connected:              return .green
        case .connecting, .scanning:  return .yellow
        case .failed:                 return .red
        case .idle:                   return .gray
        }
    }

    private var statusText: String {
        switch state.link {
        case .idle:              return "蓝牙启动中"
        case .scanning:          return "扫描 VibeBuddy-* 中"
        case .connecting(let n): return "正在连接 \(n)"
        case .connected(let n):  return "已连接：\(n)"
        case .failed(let s):     return "失败：\(s)"
        }
    }

    private var linkParamsRow: some View {
        Text("link: \(state.linkParams.phy) PHY · MTU \(state.linkParams.mtu)")
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.secondary)
            .padding(.horizontal, 4)
    }

    // MARK: transcript

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("当前转写").font(.headline)
                Spacer()
                Text(state.sttStatus)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            let primary = !state.partialText.isEmpty ? state.partialText
                        : !state.finalText.isEmpty   ? state.finalText
                        : pasteboard.currentText
            if primary.isEmpty {
                Text("（按住设备 A 按钮开始说话）")
                    .foregroundColor(.secondary).font(.callout)
            } else {
                Text(primary)
                    .font(.title3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !state.asrError.isEmpty {
                Text("ASR 错误：\(state.asrError)")
                    .font(.caption).foregroundColor(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Button {
                    pasteboard.copyAll()
                    flashCopiedToast()
                } label: {
                    Label("复制全部", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    pasteboard.commitCurrentToLog()
                } label: {
                    Label("入历史", systemImage: "text.append")
                }
                .buttonStyle(.bordered)
                .disabled(pasteboard.currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()

                if let last = pasteboard.lastCopiedAt {
                    Text("\(relativeTime(last)) 已复制")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("历史").font(.headline)
                Spacer()
                if !pasteboard.transcriptLog.isEmpty {
                    Button("清空", role: .destructive) {
                        pasteboard.clearLog()
                    }
                    .controlSize(.small)
                }
            }
            if pasteboard.transcriptLog.isEmpty {
                Text("（暂无）").foregroundColor(.secondary).font(.callout)
            } else {
                ForEach(Array(pasteboard.transcriptLog.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    Divider()
                }
            }
        }
        .padding()
        .background(.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private var debugCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("最近设备消息").font(.caption).foregroundColor(.secondary)
            Text(state.lastJSON.isEmpty ? "—" : state.lastJSON)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(.gray.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: helpers

    private func flashCopiedToast() {
        withAnimation { showCopiedToast = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation { showCopiedToast = false }
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let secs = Int(Date.now.timeIntervalSince(date))
        if secs < 5  { return "刚刚" }
        if secs < 60 { return "\(secs)s 前" }
        return "\(secs / 60)m 前"
    }
}

// MARK: - Settings sheet

private struct SettingsView: View {
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var appID: String = ""
    @State private var accessToken: String = ""
    @State private var resourceID: String = Config.defaultResourceID

    var body: some View {
        NavigationStack {
            Form {
                Section("Doubao 凭证") {
                    TextField("App ID", text: $appID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Access Token", text: $accessToken)
                    TextField("Resource ID", text: $resourceID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Text("在火山引擎控制台 · 语音技术 · 大模型流式语音识别 中获取。")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let trimmedID = appID.trimmingCharacters(in: .whitespaces)
                        let trimmedToken = accessToken.trimmingCharacters(in: .whitespaces)
                        let trimmedRes = resourceID.trimmingCharacters(in: .whitespaces)
                        Config.save(
                            appID: trimmedID,
                            accessToken: trimmedToken,
                            resourceID: trimmedRes.isEmpty ? Config.defaultResourceID : trimmedRes
                        )
                        onSaved()
                        dismiss()
                    }
                    .disabled(appID.isEmpty || accessToken.isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        // Pre-populate from existing values so editing is non-destructive.
        if let cfg = Config.load() {
            appID = cfg.appID
            accessToken = cfg.accessToken
            resourceID = cfg.resourceID
        }
    }
}
