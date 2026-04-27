import Foundation

// Platform-agnostic surface that the audio pipeline talks to whenever new
// transcript text or a hardware-button edit action arrives. macOS supplies
// a CGEvent-based implementation that types into the focused app; iOS
// cannot (Apple disallows inter-app keyboard injection) and supplies a
// UIPasteboard-backed implementation that stages text inside Vibe Buddy
// itself. The protocol is the join point that lets every other module —
// AudioStreamer, BLEController, STTService — stay platform-neutral.
@MainActor
public protocol TextHandler: AnyObject {
    // Invoked when the handler discovers it lacks the OS-level permission
    // it needs (only meaningful on macOS where Accessibility approval is
    // required; iOS handlers should leave this as a no-op).
    var onPermissionRequired: (() -> Void)? { get set }

    // Returns true iff the handler can act right now. iOS handlers always
    // return true; macOS handler checks AXIsProcessTrusted().
    func checkPermission() -> Bool

    // Streaming ASR feeds the cumulative best transcript here. Implementers
    // diff against their own mirror to decide what to do (type the suffix,
    // overwrite a buffer, etc).
    func update(to newText: String)

    // Called at the start of every recording session. Implementers should
    // forget any per-session state (the typed mirror, the staged buffer,
    // …) so the next update(to:) starts from a clean baseline.
    func reset()

    // Hardware-button edit actions originating on the device:
    //   • sendEnter:         BtnA double-tap, "newline" semantics
    //   • sendBackspaceChar: BtnB short-press, delete one character
    //   • clearAll:          long-press, wipe the focused field
    //   • rollback:          session cancelled mid-flight, undo whatever
    //                        was injected so the target app is clean
    func sendEnter()
    func sendBackspaceChar()
    func clearAll()
    func rollback()
}
