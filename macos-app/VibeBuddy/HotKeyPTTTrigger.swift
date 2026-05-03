import Foundation
import AppKit
import ApplicationServices
import VibeBuddyCore

// HotKeyPTTTrigger replaces the M5Stack hardware button when running in
// mic mode. It listens for press/release of a configurable key via a
// CGEventTap and emits the same PTTEvent vocabulary the BLE path uses,
// including the 350 ms short-press → cancel rule that mirrors the
// firmware's click-vs-hold discrimination.
//
// Default binding: Right Option (kVK_RightOption = 0x3D). It's a
// modifier so it doesn't double as a printable key, single-handed
// reachable, and not bound to anything on a stock macOS install.
//
// Permission: CGEventTap on keyboard input requires the "Input
// Monitoring" TCC grant on macOS 10.15+. tapCreate returns nil when
// it's missing — we surface that as a typed error so the UI can route
// the user to System Settings. We also handle .tapDisabledByTimeout by
// re-enabling the tap (system can disable taps under sustained load).
@MainActor
final class HotKeyPTTTrigger: PTTTrigger {

    // MARK: configuration

    // CGKeyCode for the press-to-talk modifier. Right Option's keycode
    // is 0x3D (61). To switch keys, just change this — flagsChanged
    // works for any modifier; for non-modifier keys we'd need to widen
    // the event mask to keyDown/keyUp and stop reading flag state.
    static let rightOptionKeyCode: Int64 = 0x3D
    var keyCode: Int64 = HotKeyPTTTrigger.rightOptionKeyCode

    // Held shorter than this is treated as a click → cancel session.
    // Matches the firmware's 350 ms threshold so muscle memory is
    // identical between hardware-button and hotkey modes.
    var shortPressMs: Int = 350

    // Hard cap on a single hold. If a keyUp gets eaten (Mission Control,
    // app focus loss, screen lock) we'd otherwise stream forever.
    var maxHoldSec: TimeInterval = 30

    // MARK: PTTTrigger conformance

    var onEvent: ((PTTEvent) -> Void)?

    // MARK: state

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pressed = false
    private var pressedAt: Date?
    private var watchdog: DispatchSourceTimer?
    private(set) var enabled = false

    // MARK: PTTTrigger lifecycle

    enum HotKeyError: LocalizedError {
        case tapCreateFailed
        var errorDescription: String? {
            switch self {
            case .tapCreateFailed:
                return "无法创建键盘事件监听器，请在「系统设置 → 隐私与安全性 → 输入监控」中授权 VibeBuddy。"
            }
        }
    }

    func enable() throws {
        guard !enabled else { return }

        let mask = (1 << CGEventType.flagsChanged.rawValue)
                 | (1 << CGEventType.tapDisabledByTimeout.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: HotKeyPTTTrigger.tapCallback,
            userInfo: userInfo
        ) else {
            throw HotKeyError.tapCreateFailed
        }
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = src
        self.enabled = true
        NSLog("[ptt] hotkey enabled (keycode=%lld)", keyCode)
    }

    func disable() {
        if pressed {
            // Outstanding press — bail the session cleanly so we don't
            // leave AudioStreamer / STT in active state forever.
            onEvent?(.cancel)
            pressed = false
            pressedAt = nil
        }
        cancelWatchdog()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        enabled = false
        NSLog("[ptt] hotkey disabled")
    }

    // MARK: tap callback (kernel/CFRunLoop thread, but main run loop here)

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<HotKeyPTTTrigger>.fromOpaque(refcon).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // The OS occasionally suspends taps under load or after a
            // user action. Re-enable on the main actor.
            Task { @MainActor in me.reenable() }
            return Unmanaged.passUnretained(event)
        }
        if type == .flagsChanged {
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            // Snapshot whether OUR target modifier is currently held.
            // Right Option is part of the .maskAlternate flag; we
            // disambiguate left vs right via the keycode of the event
            // that triggered the flag change.
            let down = event.flags.contains(.maskAlternate)
            if kc == me.keyCode {
                Task { @MainActor in me.handleEdge(down: down) }
            }
        }
        // listenOnly mode: we don't consume the event; the OS still
        // delivers it normally so Right Option keeps working as a
        // modifier in other apps.
        return Unmanaged.passUnretained(event)
    }

    // MARK: edge handling (main actor)

    private func reenable() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            NSLog("[ptt] tap re-enabled after timeout")
        }
    }

    private func handleEdge(down: Bool) {
        if down {
            // Defensive against repeats — flagsChanged shouldn't repeat
            // on hold the way keyDown does, but we also re-enter here
            // after .tapDisabledByTimeout if the modifier is still held.
            guard !pressed else { return }
            pressed = true
            pressedAt = Date()
            onEvent?(.start(sampleRate: 16000))
            scheduleWatchdog()
        } else {
            guard pressed, let t0 = pressedAt else { return }
            pressed = false
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
    }

    private func scheduleWatchdog() {
        cancelWatchdog()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + maxHoldSec)
        t.setEventHandler { [weak self] in
            guard let self, self.pressed else { return }
            NSLog("[ptt] watchdog (%.0fs) — forcing stop", self.maxHoldSec)
            self.pressed = false
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
