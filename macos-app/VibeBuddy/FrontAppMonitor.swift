import Foundation
import AppKit

// FrontAppMonitor watches which app is in the foreground on the Mac and
// fires onChange(name) whenever it switches. The intent is to mirror the
// focused app's name on the StickS3's screen so the user can glance at the
// device and see "where am I about to type?" — useful when the laptop is
// across the room or behind a docked monitor.
//
// We deliberately filter out our own bundle: when the user clicks the
// VibeBuddy menu/window to check status, we DON'T want to clobber the
// last meaningful app name on the device. Keeping the previous value is
// what the user actually wants to see.
//
// Source of truth is NSWorkspace.didActivateApplicationNotification, which
// fires on real app activations only — no polling, no timers.
@MainActor
final class FrontAppMonitor {

    static let shared = FrontAppMonitor()

    var onChange: ((String) -> Void)?

    private(set) var currentName: String = ""
    private let ownBundleID = Bundle.main.bundleIdentifier ?? ""
    private var observer: NSObjectProtocol?

    private init() {}

    // Start emitting. Safe to call more than once — subsequent calls are
    // no-ops because we keep the observer reference around.
    func start() {
        guard observer == nil else { return }
        let nc = NSWorkspace.shared.notificationCenter
        observer = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.handle(app)
        }
        // Seed with whoever is in front right now, so the device gets a
        // value even if the user never switches apps after launch.
        handle(NSWorkspace.shared.frontmostApplication)
    }

    // Force-emit the current value, even if it hasn't changed. Used when
    // the BLE link comes up so the device gets the initial sync without
    // waiting for the next app switch.
    func resend() {
        guard !currentName.isEmpty else { return }
        onChange?(currentName)
    }

    private func handle(_ app: NSRunningApplication?) {
        guard let app else { return }
        // Suppress self — see class comment.
        if app.bundleIdentifier == ownBundleID { return }
        guard let name = app.localizedName, !name.isEmpty else { return }
        if name == currentName { return }
        currentName = name
        NSLog("[front-app] %@", name)
        onChange?(name)
    }
}
