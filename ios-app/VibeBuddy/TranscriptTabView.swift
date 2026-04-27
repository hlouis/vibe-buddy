import SwiftUI
import VibeBuddyCore

// "转写" tab — the in-app pasteboard mode. Mirrors the original v1
// iOS layout: connection status, live partial, history, copy buttons.
// While this tab is selected the TextRouter is in pasteboard mode, so
// every ASR update lands in UIPasteboard and in the local history.
struct TranscriptTabView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pasteboard: PasteboardHandler

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
                Text("切到 \"设置\" tab 填入 App ID 与 Access Token。")
                    .font(.caption).foregroundColor(.secondary)
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
