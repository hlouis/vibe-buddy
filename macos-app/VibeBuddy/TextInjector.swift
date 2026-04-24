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
        let vkDelete: CGKeyCode = 0x33
        let down = CGEvent(keyboardEventSource: eventSource, virtualKey: vkDelete, keyDown: true)
        let up = CGEvent(keyboardEventSource: eventSource, virtualKey: vkDelete, keyDown: false)
        down?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.002)
        up?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.002)
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
