import Foundation
import VibeBuddyCore

// ButtonPTTTrigger is the iOS counterpart to macOS's HotKeyPTTTrigger.
// iOS sandboxes forbid global keyboard taps, so PTT here is driven by
// an in-app SwiftUI button calling press()/release() directly. The
// trigger itself is just a thin lifecycle wrapper around PTTSession —
// all of the click-vs-hold + watchdog logic lives in the shared core.
//
// Why a class instead of just calling PTTSession directly from the
// view? Because AudioSourceCoordinator wants to talk to "a PTTTrigger"
// uniformly — same protocol as macOS — and because enable()/disable()
// need to take effect across mode switches even while no view is on
// screen.
@MainActor
final class ButtonPTTTrigger: PTTTrigger {

    // MARK: PTTTrigger conformance

    var onEvent: ((PTTEvent) -> Void)? {
        get { session.onEvent }
        set { session.onEvent = newValue }
    }

    // MARK: state

    private let session = PTTSession()
    private(set) var enabled: Bool = false

    // MARK: PTTTrigger lifecycle

    // No OS resource to acquire on iOS — the SwiftUI gesture is the
    // event source and exists independently of this object's enable
    // state. We still gate press()/release() through `enabled` so a
    // mid-press mode switch (user backgrounds the app, or toggles
    // back to BLE) cleanly cancels the session.
    func enable() throws {
        guard !enabled else { return }
        enabled = true
        NSLog("[ptt] button trigger enabled")
    }

    func disable() {
        guard enabled else { return }
        enabled = false
        // Bail any in-flight session cleanly — equivalent to a cancel
        // edge so AudioStreamer / STT don't stay armed.
        session.reset()
        NSLog("[ptt] button trigger disabled")
    }

    // MARK: view-driven edges

    func press() {
        guard enabled else { return }
        session.down()
    }

    func release() {
        guard enabled else { return }
        session.up()
    }
}
