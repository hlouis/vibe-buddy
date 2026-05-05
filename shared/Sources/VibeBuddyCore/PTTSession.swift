import Foundation

// PTTSession owns the press/release state machine that's identical
// across every PTT trigger we ship:
//
//   • debounces repeated down() calls (key autorepeat, gesture
//     restarts, double-fired BLE notifications)
//   • applies the 350 ms short-press → cancel rule that mirrors the
//     M5Stack firmware's click-vs-hold discrimination
//   • runs a hard-cap watchdog so a missed up() (Mission Control,
//     phone call interruption, app backgrounded mid-press) doesn't
//     leave us streaming forever
//
// Both HotKeyPTTTrigger (macOS, CGEventTap) and ButtonPTTTrigger
// (iOS, SwiftUI gesture) wrap an instance of this type. The trigger
// is responsible for sourcing edge events; everything downstream
// (AudioStreamer.handlePTT) is identical.
//
// Linus principle: don't write the 350 ms logic twice. One place to
// fix bugs, one place to audit, one place to test.
@MainActor
public final class PTTSession {

    // Held shorter than this is treated as a click → cancel session.
    // Matches the firmware's 350 ms threshold so muscle memory is
    // identical between hardware-button and software-trigger modes.
    public var shortPressMs: Int = 350

    // Hard cap on a single hold. If an up() gets eaten by the OS
    // we'd otherwise stream forever — and rack up Doubao bills.
    public var maxHoldSec: TimeInterval = 30

    // What sample rate to advertise on .start. 16 kHz is the only
    // value any of our pipelines support today; exposed in case a
    // future trigger source negotiates differently.
    public var sampleRate: Int = 16000

    // Wired up by the trigger; the trigger then forwards to the
    // AudioStreamer or whatever downstream consumer it has.
    public var onEvent: ((PTTEvent) -> Void)?

    public private(set) var isPressed: Bool = false
    private var pressedAt: Date?
    private var watchdog: DispatchSourceTimer?

    public init() {}

    // Edge: user just pressed. Idempotent against autorepeat.
    public func down() {
        guard !isPressed else { return }
        isPressed = true
        pressedAt = Date()
        onEvent?(.start(sampleRate: sampleRate))
        scheduleWatchdog()
    }

    // Edge: user released. Decides between cancel (short press) and
    // stop (long press) based on hold duration.
    public func up() {
        guard isPressed, let t0 = pressedAt else { return }
        isPressed = false
        pressedAt = nil
        cancelWatchdog()
        let heldMs = Int(Date().timeIntervalSince(t0) * 1000)
        if heldMs < shortPressMs {
            NSLog("[ptt] short press (%dms) → cancel", heldMs)
            onEvent?(.cancel)
        } else {
            NSLog("[ptt] release (%dms) → stop", heldMs)
            onEvent?(.stop)
        }
    }

    // Force-cancel any in-flight session. Used when the trigger is
    // disabled mid-press (mode switch, app backgrounding).
    public func reset() {
        cancelWatchdog()
        if isPressed {
            onEvent?(.cancel)
        }
        isPressed = false
        pressedAt = nil
    }

    // MARK: watchdog

    private func scheduleWatchdog() {
        cancelWatchdog()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + maxHoldSec)
        t.setEventHandler { [weak self] in
            guard let self, self.isPressed else { return }
            NSLog("[ptt] watchdog (%.0fs) — forcing stop", self.maxHoldSec)
            self.isPressed = false
            self.pressedAt = nil
            self.onEvent?(.stop)
        }
        t.resume()
        watchdog = t
    }

    private func cancelWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }
}
