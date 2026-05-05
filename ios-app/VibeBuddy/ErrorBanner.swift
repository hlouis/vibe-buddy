import SwiftUI
import VibeBuddyCore

// ErrorBanner is the global surface for errors that the user can't
// otherwise see — namely state.hotkeyError and state.asrError, which
// the transcript tab shows inline but which are invisible from the
// browser tab / a collapsed iPad sidebar.
//
// Behavior:
//   • While there's an active error, the banner stays put — no auto-
//     hide. Errors are signal, not chatter.
//   • Tap-to-dismiss clears state.hotkeyError / state.asrError so the
//     banner goes away. If the underlying condition still holds, the
//     next operation will repopulate it (e.g. mic permission denied →
//     user dismisses → tries to record → error reappears).
//   • Mic-permission and ASR errors get visually distinguished icons
//     so the user knows whether it's a setup problem or a runtime one.
struct ErrorBanner: View {

    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if let kind = activeError {
                content(for: kind)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.85),
                   value: state.hotkeyError)
        .animation(.spring(response: 0.32, dampingFraction: 0.85),
                   value: state.asrError)
    }

    // MARK: error classification

    enum ErrorKind {
        case ptt(String)   // hotkey / mic / trigger errors
        case asr(String)   // Doubao WebSocket failures
    }

    // PTT error wins when both are set — it's the prerequisite. ASR
    // errors only matter once mic capture is working.
    private var activeError: ErrorKind? {
        if !state.hotkeyError.isEmpty { return .ptt(state.hotkeyError) }
        if !state.asrError.isEmpty    { return .asr(state.asrError) }
        return nil
    }

    // MARK: layout

    @ViewBuilder
    private func content(for kind: ErrorKind) -> some View {
        let (icon, color, message): (String, Color, String) = {
            switch kind {
            case .ptt(let m): return ("exclamationmark.triangle.fill", .orange, m)
            case .asr(let m): return ("wifi.exclamationmark", .red, "ASR：\(m)")
            }
        }()

        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 22)
            Text(message)
                .font(.callout)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
                .imageScale(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(color.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .top)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { dismiss(kind) }
    }

    private func dismiss(_ kind: ErrorKind) {
        switch kind {
        case .ptt: state.hotkeyError = ""
        case .asr: state.asrError    = ""
        }
    }
}
