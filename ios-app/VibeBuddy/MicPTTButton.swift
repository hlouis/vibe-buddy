import SwiftUI
import VibeBuddyCore

// Big round hold-to-talk button. Mounted in the transcript tab when
// state.audioSource == .mic. Translates touch-down/touch-up into
// PTTSession edges via the coordinator's ButtonPTTTrigger.
//
// Why DragGesture(minimumDistance: 0) and not LongPressGesture?
//   • DragGesture fires onChanged the instant the finger lands and
//     onEnded the instant it lifts — we get clean down/up edges
//     without the 0.5 s minimum a long press would impose.
//   • LongPressGesture only tells us "the threshold was met"; it does
//     not provide a reliable end edge if the finger slides off.
//   • DragGesture lets us implement "slide-to-cancel": if the finger
//     leaves the button bounds we treat that as a release, mirroring
//     iOS PTT muscle memory (e.g. iMessage voice memo).
struct MicPTTButton: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var coord: AudioSourceCoordinator

    // Tracked locally so the gesture handler can stay idempotent
    // against SwiftUI re-running onChanged for every translation tick.
    @State private var pressed: Bool = false
    @State private var pressedAt: Date? = nil

    // Diameter of the hit area. Big enough to thumb easily on phone,
    // not so big it dominates iPad split view.
    private let diameter: CGFloat = 140

    var body: some View {
        VStack(spacing: 12) {
            buttonCircle
            statusLabel
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    private var buttonCircle: some View {
        ZStack {
            // Outer pulse ring — animates only while pressed.
            Circle()
                .stroke(Color.red.opacity(pressed ? 0.35 : 0), lineWidth: 6)
                .frame(width: diameter + 24, height: diameter + 24)
                .scaleEffect(pressed ? 1.08 : 1.0)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                           value: pressed)

            Circle()
                .fill(pressed ? Color.red : Color.accentColor)
                .frame(width: diameter, height: diameter)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                .scaleEffect(pressed ? 0.95 : 1.0)
                .animation(.spring(response: 0.18, dampingFraction: 0.7), value: pressed)

            VStack(spacing: 4) {
                Image(systemName: pressed ? "waveform" : "mic.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
                Text(pressed ? "松开发送" : "按住说话")
                    .font(.callout).bold()
                    .foregroundStyle(.white)
            }
        }
        .contentShape(Circle())
        // minimumDistance: 0 → fires onChanged the moment the finger
        // touches down. We then dedupe ourselves below.
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    if !pressed {
                        // First touch — open the session. Coordinate is
                        // relative to the button frame; if the user
                        // started outside the circle (shouldn't happen
                        // because hit-test is the circle, but defend
                        // anyway) skip.
                        pressed = true
                        pressedAt = Date()
                        coord.pttTrigger.press()
                    } else {
                        // Slide-to-cancel: if the finger leaves the
                        // button bounds, treat as a release so the
                        // 350 ms cancel rule kicks in if it happened
                        // fast.
                        let dx = value.location.x - diameter / 2
                        let dy = value.location.y - diameter / 2
                        let r = sqrt(dx * dx + dy * dy)
                        // 1.5x diameter is generous — only triggers
                        // if the user is clearly leaving the button.
                        if r > diameter * 0.75 {
                            release()
                        }
                    }
                }
                .onEnded { _ in
                    release()
                }
        )
        .disabled(state.micAuth != .granted || !state.hotkeyEnabled)
        .opacity(state.micAuth == .granted && state.hotkeyEnabled ? 1.0 : 0.4)
    }

    @ViewBuilder private var statusLabel: some View {
        if state.micAuth != .granted {
            Text("需要麦克风权限")
                .font(.caption).foregroundStyle(.red)
        } else if !state.hotkeyError.isEmpty {
            Text(state.hotkeyError)
                .font(.caption).foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        } else if state.session?.active == true {
            Text("🔴 录音中 · 松开发送 / 短按取消")
                .font(.caption).foregroundStyle(.red)
        } else {
            Text("短按取消 · 长按超过 350ms 才会发送")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func release() {
        guard pressed else { return }
        pressed = false
        pressedAt = nil
        coord.pttTrigger.release()
    }
}
