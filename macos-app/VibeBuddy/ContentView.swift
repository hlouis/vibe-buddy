import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()
            statusRow
            if case .connected = state.link {
                linkParamsRow
            }
            Divider()
            audioRow
            Divider()
            jsonRow
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 380)
    }

    private var header: some View {
        HStack {
            Text("Vibe Buddy").font(.largeTitle).bold()
            Spacer()
            Text("phase 1 · step 5")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            Circle().fill(statusColor).frame(width: 12, height: 12)
            Text(statusText)
                .font(.body)
            Spacer()
        }
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
        case .idle:                   return "Bluetooth powering up"
        case .scanning:               return "scanning for VibeBuddy-*"
        case .connecting(let n):      return "connecting to \(n)"
        case .connected(let n):       return "connected: \(n)"
        case .failed(let s):          return "failed: \(s)"
        }
    }

    private var linkParamsRow: some View {
        Text("link: \(state.linkParams.phy) PHY · MTU \(state.linkParams.mtu)")
            .font(.system(.callout, design: .monospaced))
            .foregroundColor(.secondary)
    }

    @ViewBuilder private var audioRow: some View {
        if let s = state.session {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(s.active ? "🎙 recording" : "✔ last session")
                        .font(.headline)
                        .foregroundColor(s.active ? .red : .primary)
                    Spacer()
                    Text("\(state.totalSessions) done")
                        .font(.caption).foregroundColor(.secondary)
                }
                Text(String(format: "bytes=%d  gaps=%d  rate=%dHz  dur=%.1fs",
                            s.bytes, s.gaps, s.sampleRate,
                            Double(s.bytes) / max(Double(s.sampleRate * 2), 1)))
                    .font(.system(.caption, design: .monospaced))
                if let path = state.lastDumpPath, !s.active {
                    Text("pcm: \(path)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
        } else {
            Text("no audio session yet — hold the A button on the device")
                .font(.callout)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder private var jsonRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("last message")
                .font(.caption).foregroundColor(.secondary)
            Text(state.lastJSON.isEmpty ? "—" : state.lastJSON)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
        }
    }
}

#Preview {
    let s = AppState()
    s.link = .connected("VibeBuddy-67AD")
    s.linkParams = .init(phy: "2M", mtu: 517)
    s.lastJSON = #"{"type":"link","phy":"2M","mtu":517}"#
    return ContentView().environmentObject(s)
}
