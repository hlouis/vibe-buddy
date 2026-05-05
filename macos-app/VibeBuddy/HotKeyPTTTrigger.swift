import Foundation
import AppKit
import ApplicationServices
import VibeBuddyCore

// HotKeyPTTTrigger replaces the M5Stack hardware button when running in
// mic mode. It listens for press/release of a configurable key via a
// CGEventTap and forwards the down/up edges to a shared PTTSession,
// which handles the 350 ms short-press → cancel rule, watchdog, and
// PTTEvent emission. Same logic as ButtonPTTTrigger on iOS — the
// platform-specific work here is purely "how do I observe the key".
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

    // MARK: PTTTrigger conformance

    var onEvent: ((PTTEvent) -> Void)? {
        get { session.onEvent }
        set { session.onEvent = newValue }
    }

    // MARK: state

    private let session = PTTSession()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
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
        // Bails any in-flight session cleanly — equivalent to a cancel
        // edge so AudioStreamer / STT don't stay armed.
        session.reset()
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

    // MARK: tap callback (CFRunLoop thread, dispatched to main)

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
                Task { @MainActor in
                    if down {
                        me.session.down()
                    } else {
                        me.session.up()
                    }
                }
            }
        }
        // listenOnly mode: we don't consume the event; the OS still
        // delivers it normally so Right Option keeps working as a
        // modifier in other apps.
        return Unmanaged.passUnretained(event)
    }

    private func reenable() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            NSLog("[ptt] tap re-enabled after timeout")
        }
    }
}
