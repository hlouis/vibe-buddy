import Foundation
import ApplicationServices
import AppKit

// FocusGate decides whether the system-wide focused UI element can accept
// keyboard input. Without this gate, ASR text gets injected into whatever
// app is in front — if the focus is on a button or empty desktop, every
// keystroke triggers macOS's "ding" funk sound.
//
// Policy is permissive: when AX can't tell us (Electron, web views, AX
// query failure), we let injection through. Better to over-inject than
// to silently swallow user transcripts. Never break userspace.
//
// We snapshot once per session (driven by TextInjector.reset(), which is
// called from AudioStreamer.startSession()) rather than per-keystroke. AX
// queries are synchronous cross-process IPC; one per ASR partial would
// stall the typing queue when the target app's main thread is busy.
@MainActor
final class FocusGate {

    static let shared = FocusGate()

    private(set) var isEditable: Bool = true
    private(set) var lastFocusDescription: String = "(unknown)"

    var onChange: ((Bool, String) -> Void)?

    private init() {}

    @discardableResult
    func refresh() -> Bool {
        let (editable, desc) = Self.probeFocusedElement()
        if editable != isEditable || desc != lastFocusDescription {
            isEditable = editable
            lastFocusDescription = desc
            onChange?(editable, desc)
        }
        NSLog("[focus] editable=%@ focus=%@", editable ? "YES" : "NO", desc)
        return editable
    }

    // Returns (isEditable, humanReadableDescription). Permissive: returns
    // true on any uncertainty so we don't accidentally silence valid input.
    private static func probeFocusedElement() -> (Bool, String) {
        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"

        let sys = AXUIElementCreateSystemWide()
        var raw: AnyObject?
        let err = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &raw)
        guard err == .success, let any = raw else {
            // No focused element exposed (non-AX app, or AX query failed) — allow.
            return (true, "\(frontApp): no focused element (allow)")
        }
        let focused = any as! AXUIElement

        // Primary signal: kAXValueAttribute is settable on text-bearing controls.
        var settable: DarwinBoolean = false
        let sErr = AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable)
        if sErr == .success && settable.boolValue {
            return (true, "\(frontApp): value settable")
        }

        // Fallback: role whitelist. Catches text controls whose settable
        // flag isn't exposed (some Electron / web hosts).
        var roleRaw: AnyObject?
        let role = (AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &roleRaw) == .success)
            ? (roleRaw as? String ?? "?") : "?"
        let editableRoles: Set<String> = [
            "AXTextField", "AXTextArea", "AXComboBox",
            "AXSearchField", "AXSecureTextField",
            "AXWebArea",   // web/Electron — be permissive
        ]
        if editableRoles.contains(role) {
            return (true, "\(frontApp): role=\(role)")
        }

        // Some apps expose selected-text even when value isn't settable.
        var selRaw: AnyObject?
        if AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &selRaw) == .success {
            return (true, "\(frontApp): has selected-text (role=\(role))")
        }

        return (false, "\(frontApp): role=\(role) not editable")
    }
}
