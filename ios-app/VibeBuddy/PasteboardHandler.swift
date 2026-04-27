import Foundation
import UIKit
import Combine
import VibeBuddyCore

// iOS counterpart to macOS's TextInjector. iOS forbids inter-app keyboard
// injection, so instead of typing into the focused app we stage every
// transcript in two places:
//
//   1. UIPasteboard.general — so the user can switch to any other app
//      and paste with one gesture.
//   2. A local published `currentText` buffer the in-app UI mirrors,
//      with a session-spanning `transcriptLog` that records every final
//      result so a long capture session ends with a usable history.
//
// The hardware-button edit actions (BtnA newline, BtnB backspace, long-
// press clear) operate on this in-app buffer rather than on whatever the
// user is doing outside Vibe Buddy. That's the closest analogue we get on
// a sandboxed platform.
@MainActor
final class PasteboardHandler: ObservableObject, TextHandler {

    // Settable by AudioStreamer; we never need it on iOS so it's a no-op
    // sink that just satisfies the protocol contract.
    var onPermissionRequired: (() -> Void)?

    // Live-updating mirrors that the SwiftUI ContentView reads directly.
    // currentText is the in-flight transcript for the current recording;
    // transcriptLog is the running history of finalized utterances.
    @Published private(set) var currentText: String = ""
    @Published private(set) var transcriptLog: [String] = []
    @Published private(set) var lastCopiedAt: Date? = nil

    // iOS has no Accessibility-style permission gate for this kind of
    // operation, so we always report ourselves as ready.
    func checkPermission() -> Bool { true }

    // MARK: streaming ASR updates

    func update(to newText: String) {
        currentText = newText
        // Mirror to the system pasteboard so the user can paste even
        // mid-utterance. UIPasteboard writes are cheap (a single XPC
        // call) and replace the previous value, so partial spam is fine.
        if !newText.isEmpty {
            UIPasteboard.general.string = newText
            lastCopiedAt = .now
        }
    }

    func reset() {
        currentText = ""
    }

    // MARK: hardware-button edit actions

    func sendEnter() {
        // BtnA double-tap on macOS dispatches Return. On iOS we treat
        // this as "commit the current line into the log and start
        // fresh." The pasteboard keeps the joined view so a single
        // paste produces the full conversation.
        commitCurrentToLog()
        UIPasteboard.general.string = transcriptLog.joined(separator: "\n")
        lastCopiedAt = .now
    }

    func sendBackspaceChar() {
        // Trim one character off the staged text. Mirrors macOS's
        // single-char delete semantics, scoped to our buffer.
        if !currentText.isEmpty {
            currentText = String(currentText.dropLast())
            UIPasteboard.general.string = currentText
            lastCopiedAt = .now
        } else if !transcriptLog.isEmpty {
            transcriptLog.removeLast()
        }
    }

    func clearAll() {
        currentText = ""
        transcriptLog.removeAll()
        UIPasteboard.general.string = ""
    }

    func rollback() {
        // Session was cancelled; drop in-flight text. Don't touch the
        // log — those entries are already finalized.
        currentText = ""
    }

    // MARK: in-app helpers (called from ContentView)

    func commitCurrentToLog() {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        transcriptLog.append(trimmed)
        currentText = ""
    }

    func copyAll() {
        var pieces = transcriptLog
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { pieces.append(trimmed) }
        let joined = pieces.joined(separator: "\n")
        UIPasteboard.general.string = joined
        lastCopiedAt = .now
    }

    func clearLog() {
        transcriptLog.removeAll()
    }
}
