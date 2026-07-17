import SwiftUI
import AppKit
import VibeBuddyCore

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var ble: BLEController
    @EnvironmentObject var coord: AudioSourceCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            warnings
            sourceRow
            statusRow
            if case .connected = state.link, state.audioSource == .bluetooth { linkParamsRow }
            if state.audioSource == .mic { micRow }
            Divider()
            audioRow
            Divider()
            sttRow
            Divider()
            jsonRow
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 480)
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
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Doubao config missing").font(.callout).bold()
                        Text("ASR 功能需要先填入 Doubao 凭证。")
                            .font(.caption).foregroundColor(.secondary)
                        Button("打开设置…") { openSettingsWindow() }
                            .controlSize(.small)
                    }
                }
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

    // Source picker: Bluetooth (default, hardware device) vs Mic
    // (system microphone + global hotkey PTT). Switching tears down
    // any in-flight session and rewires AudioStreamer's input.
    private var sourceRow: some View {
        HStack(spacing: 10) {
            Image(systemName: state.audioSource == .bluetooth ? "dot.radiowaves.left.and.right" : "mic.fill")
                .foregroundColor(state.audioSource == .bluetooth ? .blue : .purple)
            Picker("音频来源", selection: Binding(
                get: { state.audioSource },
                set: { coord.switchTo($0) }
            )) {
                Text("VibeBuddy 蓝牙设备").tag(AppState.AudioSource.bluetooth)
                Text("系统麦克风 (PTT)").tag(AppState.AudioSource.mic)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            Spacer()
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
        if state.audioSource == .mic {
            if state.micAuth != .granted { return .red }
            if !state.hotkeyEnabled       { return .yellow }
            if state.session?.active == true { return .red }
            return .green
        }
        switch state.link {
        case .connected:              return .green
        case .connecting, .scanning:  return .yellow
        case .failed:                 return .red
        case .idle:                   return .gray
        }
    }

    private var statusText: String {
        if state.audioSource == .mic {
            switch state.micAuth {
            case .denied:        return "麦克风权限被拒绝 — 前往系统设置开启"
            case .notDetermined: return "等待麦克风授权"
            case .granted:
                if state.session?.active == true {
                    return "🔴 录音中 · 松开 ⌥ 发送 / 短按取消"
                }
                if !state.hotkeyEnabled {
                    return "麦克风就绪 · 全局快捷键未启用"
                }
                return "麦克风就绪 · \(state.hotkeyHint)"
            case .unknown:       return "正在检查麦克风权限"
            }
        }
        switch state.link {
        case .idle:              return "Bluetooth powering up"
        case .scanning:          return "scanning for VibeBuddy-*"
        case .connecting(let n): return "connecting to \(n)"
        case .connected(let n):  return "connected: \(n)"
        case .failed(let s):     return "failed: \(s)"
        }
    }

    // Mic-mode-specific subrow: shows two permission gates (mic +
    // input monitoring) with deep-link buttons. The input-monitoring
    // gate auto-recovers when the user grants permission and switches
    // back to this window — see AudioSourceCoordinator.refreshPermissionsOnFocus.
    @ViewBuilder private var micRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.micAuth == .denied {
                HStack(spacing: 8) {
                    Image(systemName: "mic.slash.fill").foregroundColor(.red)
                    Text("VibeBuddy 没有麦克风权限。")
                        .font(.callout)
                    Button("打开「麦克风」设置") { coord.openMicSettings() }
                        .controlSize(.small)
                }
            }
            if state.inputMonitoringAuth != .granted {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: state.inputMonitoringAuth == .denied
                          ? "keyboard.badge.eye"
                          : "keyboard.badge.ellipsis")
                        .foregroundColor(state.inputMonitoringAuth == .denied ? .red : .orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(inputMonitoringMessage)
                            .font(.callout)
                        Text("授权后回到 VibeBuddy 窗口会自动启用，无需重启 app。")
                            .font(.caption).foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            Button("打开「输入监控」设置") { coord.openInputMonitoringSettings() }
                                .controlSize(.small)
                            Button("重试") { coord.retryHotkey() }
                                .controlSize(.small)
                        }
                    }
                }
            } else if !state.hotkeyError.isEmpty {
                // Input monitoring is granted but tap creation still
                // failed somehow — surface the raw error.
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.hotkeyError)
                            .font(.caption).foregroundColor(.secondary)
                            .textSelection(.enabled)
                        Button("重试") { coord.retryHotkey() }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private var inputMonitoringMessage: String {
        switch state.inputMonitoringAuth {
        case .denied:
            return "「输入监控」权限被拒绝 — 全局快捷键无法工作。"
        case .notDetermined, .unknown:
            return "需要「输入监控」权限来监听 Right Option 全局快捷键。"
        case .granted:
            return ""   // not shown
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
                // dur comes from the streamer, not from bytes: `bytes` is
                // raw PCM in mic mode but compressed Opus over BLE, so
                // the old bytes/(rate*2) math read ~12x short there.
                Text(String(
                    format: "bytes=%d (%@)  gaps=%d  rate=%dHz  dur=%.1fs",
                    s.bytes, s.codec.rawValue, s.gaps, s.sampleRate, s.durationSec
                ))
                .font(.system(.caption, design: .monospaced))
                if let path = state.lastDumpPath, !s.active {
                    Text("\(s.codec == .opus ? "ogg" : "pcm"): \(path)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
        } else {
            Text(state.audioSource == .bluetooth
                 ? "no audio session yet — hold the A button on the device"
                 : "尚无录音 — 按住 ⌥ Right Option 说话（短按取消）")
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
            if !state.focusEditable, state.session?.active == true {
                HStack(spacing: 6) {
                    Image(systemName: "keyboard.badge.ellipsis")
                        .foregroundColor(.orange)
                    Text("focus not editable — typing paused (\(state.focusDescription))")
                        .font(.caption).foregroundColor(.secondary)
                }
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

    // SwiftUI doesn't expose a typed "open Settings scene" API on
    // macOS 14 — the cross-version trick is to send the standard
    // "showSettingsWindow:" Cocoa selector, which the Settings { }
    // scene installs as the Cmd+, action.
    private func openSettingsWindow() {
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
