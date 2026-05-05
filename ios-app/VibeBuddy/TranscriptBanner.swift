import SwiftUI
import VibeBuddyCore

// TranscriptBanner is a top-of-screen toast that mirrors the live
// ASR text onto whichever screen the user happens to be on. The
// transcript tab shows this content inline already; this banner is
// the "I'm in the browser tab but I want to see what I said" surface.
//
// Behavior:
//   • While the session is active (state.session?.active == true) the
//     latest partialText is shown live. No auto-hide — recording is
//     happening, so the banner staying visible is exactly right.
//   • When the session ends, the banner stays for `lingerSeconds`
//     more seconds with the final text, then fades out. This gives
//     the user a moment to read what got transcribed before it's
//     gone — same UX as iOS's ephemeral notification toasts.
//   • If a new session starts before the linger expires, the timer
//     is cancelled and we go straight back into live mode.
//
// Caller decides when to mount this view (typically: in the same
// places the FloatingPTTOrb is shown — i.e. screens that don't have
// the inline transcript card).
struct TranscriptBanner: View {

    @EnvironmentObject var state: AppState

    // How long the final text lingers after a session ends.
    private let lingerSeconds: Double = 3.0

    // What's currently visible in the banner. Driven by the state
    // change handlers below; an empty string hides the banner.
    @State private var displayed: String = ""

    // Tracks whether we're showing live partial (recording) or
    // lingering final (post-recording fade).
    @State private var mode: Mode = .hidden
    @State private var hideTask: Task<Void, Never>? = nil

    enum Mode {
        case hidden
        case live       // recording in progress
        case linger     // recording ended, fading out window
    }

    var body: some View {
        Group {
            if !displayed.isEmpty {
                content
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.85),
                   value: displayed)
        .onChange(of: state.partialText)             { _, t in handlePartial(t) }
        .onChange(of: state.finalText)               { _, t in handleFinal(t) }
        .onChange(of: state.session?.active ?? false) { _, active in
            handleSessionActive(active)
        }
    }

    // MARK: layout

    private var content: some View {
        HStack(spacing: 10) {
            Image(systemName: mode == .live ? "waveform" : "checkmark.circle.fill")
                .foregroundStyle(mode == .live ? .red : .green)
                .symbolEffect(.pulse, options: .repeat(.continuous), isActive: mode == .live)
                .frame(width: 22)
            Text(displayed)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.head)  // newer characters are at the end; truncate head
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .top)
        .onTapGesture {
            // Tap-to-dismiss for the linger phase; live mode ignores
            // the tap (we're still showing fresh content).
            if mode == .linger { hideNow() }
        }
    }

    // MARK: state transitions

    private func handlePartial(_ text: String) {
        guard !text.isEmpty else { return }
        cancelHide()
        displayed = text
        mode = .live
    }

    private func handleFinal(_ text: String) {
        guard !text.isEmpty else { return }
        // Final text supersedes any partial currently shown.
        displayed = text
        mode = .linger
        scheduleLingerHide()
    }

    private func handleSessionActive(_ active: Bool) {
        if active {
            // New session started — cancel any pending linger so the
            // outgoing final text doesn't wipe the new partial.
            cancelHide()
            // Don't clear `displayed` yet — wait for the first partial
            // to arrive. Otherwise the banner flickers.
        } else if mode == .live {
            // Session just ended; we have a partial but no final yet
            // (e.g. user cancelled / very short hold). Linger anyway
            // so they can see what was being transcribed.
            mode = .linger
            scheduleLingerHide()
        }
    }

    private func scheduleLingerHide() {
        cancelHide()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(lingerSeconds * 1_000_000_000))
            if !Task.isCancelled, mode == .linger {
                hideNow()
            }
        }
    }

    private func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    private func hideNow() {
        cancelHide()
        displayed = ""
        mode = .hidden
    }
}
