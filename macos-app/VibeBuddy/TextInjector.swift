import Foundation
import ApplicationServices
import AppKit

// Accessibility-based keystroke injection with incremental diff updates.
//
// The streaming ASR emits cumulative text that may correct earlier
// outputs. We keep a mirror of what's been typed and, for every new
// cumulative string, compute the longest common prefix: backspace the
// divergent tail, then type the new suffix. Unicode characters are
// emitted via CGEventKeyboardSetUnicodeString so we bypass keyboard
// layout / input-method quirks entirely.
final class TextInjector {

    // MARK: state (written only on main actor)

    @MainActor private var injectedText: String = ""
    @MainActor var onPermissionRequired: (() -> Void)?

    // CGEvents can post from any thread; keep typing on a dedicated
    // serial queue so bursty partial updates from ASR don't interleave
    // or pile up on the main thread.
    private let typingQueue = DispatchQueue(label: "com.yourname.vibebuddy.typing", qos: .userInitiated)
    private let eventSource = CGEventSource(stateID: .hidSystemState)

    // MARK: permission

    @discardableResult
    func checkPermission(prompt: Bool = false) -> Bool {
        if prompt {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let opts = [key: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(opts)
        }
        return AXIsProcessTrusted()
    }

    // MARK: public API (main actor)

    @MainActor
    func update(to newText: String) {
        guard checkPermission() else {
            onPermissionRequired?()
            return
        }
        let commonLen = injectedText.commonPrefix(with: newText).count
        let currentLen = injectedText.count
        let backspaces = currentLen - commonLen

        let suffix: String
        if commonLen < newText.count {
            let start = newText.index(newText.startIndex, offsetBy: commonLen)
            suffix = String(newText[start...])
        } else {
            suffix = ""
        }

        injectedText = newText

        typingQueue.async { [weak self] in
            guard let self else { return }
            for _ in 0..<backspaces {
                self.sendBackspace()
            }
            if !suffix.isEmpty {
                self.typeUnicode(suffix)
            }
        }
    }

    @MainActor
    func reset() {
        injectedText = ""
    }

    // MARK: hardware-button edit actions

    @MainActor
    func sendEnter() {
        guard checkPermission() else { onPermissionRequired?(); return }
        // Cursor moved to a new line — the previous injection mirror no
        // longer maps onto the current field contents, so start fresh.
        injectedText = ""
        typingQueue.async { [weak self] in
            self?.postKey(0x24)   // kVK_Return
        }
    }

    @MainActor
    func sendBackspaceChar() {
        guard checkPermission() else { onPermissionRequired?(); return }
        if !injectedText.isEmpty {
            injectedText = String(injectedText.dropLast())
        }
        typingQueue.async { [weak self] in
            self?.sendBackspace()
        }
    }

    // Cmd+A then delete. Wipes the ENTIRE focused field, not just the
    // text we injected — user asked for "clear all" semantics.
    @MainActor
    func clearAll() {
        guard checkPermission() else { onPermissionRequired?(); return }
        injectedText = ""
        typingQueue.async { [weak self] in
            self?.sendSelectAll()
            Thread.sleep(forTimeInterval: 0.020)
            self?.sendBackspace()
        }
    }

    // Rollback when a session is cancelled: backspace out everything we
    // injected so the target app is clean.
    @MainActor
    func rollback() {
        let n = injectedText.count
        injectedText = ""
        guard n > 0, checkPermission() else { return }
        typingQueue.async { [weak self] in
            guard let self else { return }
            for _ in 0..<n {
                self.sendBackspace()
            }
        }
    }

    // MARK: CGEvent plumbing (background queue)

    private func sendBackspace() {
        postKey(0x33)   // kVK_Delete
    }

    private func postKey(_ keyCode: CGKeyCode) {
        guard let down = CGEvent(keyboardEventSource: eventSource,
                                 virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: eventSource,
                               virtualKey: keyCode, keyDown: false)
        else { return }
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.002)
        up.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.002)
    }

    private func sendSelectAll() {
        let vkA: CGKeyCode = 0x00   // 'a'
        guard let down = CGEvent(keyboardEventSource: eventSource,
                                 virtualKey: vkA, keyDown: true),
              let up = CGEvent(keyboardEventSource: eventSource,
                               virtualKey: vkA, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.003)
        up.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.003)
    }

    // Use UnicodeString injection so we never translate through a
    // physical key — otherwise Chinese IME would intercept each char.
    private func typeUnicode(_ text: String) {
        for char in text {
            let utf16 = Array(String(char).utf16)
            guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false)
            else { continue }
            utf16.withUnsafeBufferPointer { ptr in
                if let base = ptr.baseAddress {
                    down.keyboardSetUnicodeString(stringLength: ptr.count, unicodeString: base)
                    up.keyboardSetUnicodeString(stringLength: ptr.count, unicodeString: base)
                }
            }
            down.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.002)
            up.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.002)
        }
    }
}
