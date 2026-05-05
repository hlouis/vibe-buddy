import SwiftUI
import VibeBuddyCore

// FloatingPTTOrb is the always-on PTT button for screens that don't
// have the big in-line MicPTTButton — i.e. the browser tab on iPhone
// and the iPad detail when the sidebar is collapsed.
//
// Position model (v2):
//   • Free 2D positioning anywhere inside the parent's GeometryReader.
//   • Persisted as raw (x, y) in @AppStorage. On launch we clamp into
//     the current geometry so rotation / iPad multitasking / split
//     view changes don't strand the orb off-screen.
//   • Edge snap is per-axis: after a drag, each of the four edges is
//     checked independently. Within `snapDistance` of an edge → that
//     axis snaps. Within snapDistance of two edges → corner emerges
//     naturally from two snaps. No special "corner" enum required.
//
// Gesture model: same as v1.
//   • Touch with translation < dragThreshold → press-and-hold PTT
//     (forwarded to coord.pttTrigger). The 350 ms short-press cancel
//     rule from PTTSession applies, so a quick tap dismisses without
//     sending.
//   • Touch that exceeds dragThreshold at any point → reposition.
//     The orb cancels any in-flight press first (PTTSession sees
//     <350 ms hold and emits .cancel), then follows the finger.
struct FloatingPTTOrb: View {

    // MARK: configuration

    private let visualSize: CGFloat = 56

    // Pixels the finger has to travel before we abandon "press-and-
    // hold PTT" interpretation and switch to "reposition orb". 60 pt
    // is well above natural hand jitter on a long PTT hold.
    private let dragThreshold: CGFloat = 60

    // Distance from an edge inside which the orb snaps to that edge.
    // Tuning history:
    //   • 28 pt — felt "too loose", user could release near an edge
    //     and the orb wouldn't catch.
    //   • 56 pt (current) — one full orb diameter. iOS AssistiveTouch
    //     uses a similarly generous threshold; below this the magnet
    //     metaphor breaks down.
    // Free-place territory is everything farther than this from any
    // edge — still plenty of room in the middle of the screen.
    private let snapDistance: CGFloat = 56

    // Padding from the snapped edge to the orb edge (so the orb
    // doesn't touch the bezel on a snap).
    private let edgePadding: CGFloat = 12

    // Caller-supplied bottom inset. iPhone passes 70 to clear the
    // TabBar; iPad passes 24 (no TabBar). The container's padding
    // shrinks the GeometryReader, so the bottom edge for snapping is
    // already TabBar-clear.
    var bottomInset: CGFloat = 16

    // Caller-supplied top inset (e.g. clears nav bar / address bar).
    // 12 default: GeometryReader is usually inside a safe-area-aware
    // container so 12 pt of breathing room is enough.
    var topInset: CGFloat = 12

    // MARK: env

    @EnvironmentObject var coord: AudioSourceCoordinator
    @EnvironmentObject var state: AppState

    // MARK: persistence
    //
    // CGPoint can't be @AppStorage'd directly. We persist x and y as
    // doubles. -1 is the sentinel for "never positioned" → caller
    // computes default on first appear from the actual container size.
    @AppStorage("pttOrbX") private var savedX: Double = -1
    @AppStorage("pttOrbY") private var savedY: Double = -1

    // MARK: gesture state

    @State private var pressed = false                 // PTT held
    @State private var dragging = false                // reposition active
    @State private var dragStartCenter: CGPoint? = nil // orb pos at drag start

    // Live position. Set on first appear from saved or default.
    @State private var center: CGPoint = .init(x: -1, y: -1)

    // MARK: layout

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.clear
                orbCircle
                    .position(center)
                    .gesture(combinedGesture(in: geo.size))
                    // Animate snaps on release; keep drag itself
                    // unanimated so the orb tracks the finger 1:1.
                    .animation(dragging ? nil
                                : .spring(response: 0.35, dampingFraction: 0.78),
                               value: center)
            }
            .onAppear { initializePosition(in: geo.size) }
            .onChange(of: geo.size) { _, newSize in
                // Container resized (rotation, multitasking) — clamp
                // back into bounds so the orb doesn't end up off-screen.
                center = clamp(center, into: newSize)
                persist()
            }
        }
        // Caller-supplied insets shrink our movable area to exclude
        // chrome (TabBar at the bottom, nav bar at the top).
        .padding(.top, topInset)
        .padding(.bottom, bottomInset)
        .ignoresSafeArea(.keyboard)
        .allowsHitTesting(state.audioSource == .mic)
    }

    // MARK: visual

    private var orbCircle: some View {
        ZStack {
            Circle()
                .stroke(Color.red.opacity(pressed ? 0.4 : 0), lineWidth: 5)
                .frame(width: visualSize + 22, height: visualSize + 22)
                .scaleEffect(pressed ? 1.10 : 1.0)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                           value: pressed)

            Circle()
                .fill(pressed ? Color.red : Color.accentColor)
                .frame(width: visualSize, height: visualSize)
                .shadow(color: .black.opacity(0.22), radius: 6, y: 2)

            Image(systemName: pressed ? "waveform" : "mic.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
        }
        .opacity(idleOpacity)
        .scaleEffect(dragging ? 1.08 : (pressed ? 0.96 : 1.0))
        .contentShape(Circle())
        .frame(width: visualSize + 24, height: visualSize + 24)
    }

    private var idleOpacity: Double {
        if pressed || dragging { return 1.0 }
        return state.audioSource == .mic ? 0.72 : 0.4
    }

    // MARK: gesture

    // Gesture needs the container size for snap math on release —
    // captured here from the parent GeometryReader.
    private func combinedGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { handleDragChanged($0) }
            .onEnded   { handleDragEnded($0, size: size) }
    }

    private func handleDragChanged(_ value: DragGesture.Value) {
        let dist = hypot(value.translation.width, value.translation.height)

        if !pressed && !dragging {
            // First touch: optimistically PTT. If this turns into a
            // drag (next branch) we cancel.
            pressed = true
            coord.pttTrigger.press()
            haptic(.medium)
            return
        }

        if pressed && dist > dragThreshold {
            // Crossed threshold → reposition, not talk.
            coord.pttTrigger.release()  // PTTSession emits .cancel for <350 ms
            pressed = false
            dragging = true
            dragStartCenter = center
            haptic(.heavy)
            // Fall through to update position immediately.
        }

        if dragging, let start = dragStartCenter {
            center = CGPoint(x: start.x + value.translation.width,
                             y: start.y + value.translation.height)
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value, size: CGSize) {
        if pressed {
            pressed = false
            coord.pttTrigger.release()
            return
        }
        if dragging {
            dragging = false
            dragStartCenter = nil
            // Per-axis edge snap. Each axis snaps independently — if
            // we're near both the right edge and the bottom edge, we
            // get a bottom-right corner snap from two single-axis snaps,
            // no special "corner" code path required.
            //
            // Order matters: clamp first (keep center inside bounds),
            // then snap (move to nearest edge if within threshold). The
            // animation on the .position binding will tween to the
            // snapped destination.
            center = snap(clamp(center, into: size), into: size)
            haptic(.light)
            persist()
        }
    }

    // MARK: positioning

    // First-time placement: bottom-right with edge padding. Restored
    // positions get clamped into the new geometry.
    private func initializePosition(in size: CGSize) {
        if center.x < 0 || center.y < 0 {
            if savedX >= 0 && savedY >= 0 {
                center = CGPoint(x: CGFloat(savedX), y: CGFloat(savedY))
            } else {
                let r = visualSize / 2 + edgePadding
                center = CGPoint(x: size.width - r, y: size.height - r)
            }
        }
        center = clamp(center, into: size)
    }

    // Hard bounds: orb center must be at least `r` from every edge,
    // otherwise the visual sticks out past the container.
    private func clamp(_ p: CGPoint, into size: CGSize) -> CGPoint {
        let r = visualSize / 2
        return CGPoint(
            x: max(r, min(size.width  - r, p.x)),
            y: max(r, min(size.height - r, p.y))
        )
    }

    // Per-axis edge snap. Within `snapDistance` of any of the four
    // edges → that axis locks to (edge + r + edgePadding). Two-edge
    // proximity yields a corner snap from two independent single-axis
    // snaps — no special-case code needed (Linus:消除特殊情况).
    private func snap(_ p: CGPoint, into size: CGSize) -> CGPoint {
        let r = visualSize / 2
        let leftEdge   = r + edgePadding
        let rightEdge  = size.width - r - edgePadding
        let topEdge    = r + edgePadding
        let bottomEdge = size.height - r - edgePadding

        var s = p
        if abs(p.x - leftEdge)   < snapDistance { s.x = leftEdge }
        if abs(p.x - rightEdge)  < snapDistance { s.x = rightEdge }
        if abs(p.y - topEdge)    < snapDistance { s.y = topEdge }
        if abs(p.y - bottomEdge) < snapDistance { s.y = bottomEdge }
        return s
    }

    private func persist() {
        savedX = Double(center.x)
        savedY = Double(center.y)
    }

    // MARK: haptics

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let g = UIImpactFeedbackGenerator(style: style)
        g.prepare()
        g.impactOccurred()
    }
}
