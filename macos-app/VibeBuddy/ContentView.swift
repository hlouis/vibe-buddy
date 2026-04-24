import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var ble: BLEController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            warnings
            statusRow
            if case .connected = state.link { linkParamsRow }
            Divider()
            audioRow
            Divider()
            sttRow
            Divider()
            jsonRow
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 460)
    }

    // MARK: sections

    private var header: some View {
        HStack {
            Text("Vibe Buddy").font(.largeTitle).bold()
            Spacer()
            Text("phase 1 · step 6")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    @ViewBuilder private var warnings: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.configMissing {
                warning(
                    icon: "exclamationmark.triangle.fill",
                    color: .orange,
                    title: "Doubao config missing",
                    detail: "Create \(Config.configURL().path) — see README."
                )
            }
            if !state.accessibilityTrusted {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield")
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Accessibility not granted")
                            .font(.callout).bold()
                        Text("Vibe Buddy needs keyboard-injection access to type transcripts into other apps.")
                            .font(.caption).foregroundColor(.secondary)
                        Button("Open System Settings…") {
                            openAccessibilityPane()
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func warning(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundColor(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).bold()
                Text(detail).font(.caption).foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            Circle().fill(statusColor).frame(width: 12, height: 12)
            Text(statusText).font(.body)
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
        case .idle:              return "Bluetooth powering up"
        case .scanning:          return "scanning for VibeBuddy-*"
        case .connecting(let n): return "connecting to \(n)"
        case .connected(let n):  return "connected: \(n)"
        case .failed(let s):     return "failed: \(s)"
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
                Text(String(
                    format: "bytes=%d  gaps=%d  rate=%dHz  dur=%.1fs",
                    s.bytes, s.gaps, s.sampleRate,
                    Double(s.bytes) / max(Double(s.sampleRate * 2), 1)
                ))
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

    @ViewBuilder private var sttRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Doubao ASR").font(.headline)
                Spacer()
                Text(state.sttStatus)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            if !state.partialText.isEmpty {
                Text(state.partialText)
                    .foregroundColor(.blue)
                    .font(.system(.body, design: .default))
                    .textSelection(.enabled)
            } else if !state.finalText.isEmpty {
                Text(state.finalText)
                    .foregroundColor(.primary)
                    .font(.system(.body, design: .default))
                    .textSelection(.enabled)
            } else {
                Text("(no transcript yet)")
                    .foregroundColor(.secondary).font(.caption)
            }
            if !state.asrError.isEmpty {
                Text("error: \(state.asrError)")
                    .foregroundColor(.red).font(.caption)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var jsonRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("last device message").font(.caption).foregroundColor(.secondary)
            Text(state.lastJSON.isEmpty ? "—" : state.lastJSON)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }

    // MARK: helpers

    private func openAccessibilityPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
