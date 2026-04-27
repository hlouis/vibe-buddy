import SwiftUI
import VibeBuddyCore

@main
struct VibeBuddyApp: App {
    @StateObject private var state = AppState()
    @StateObject private var ble = BLEController(textHandler: TextInjector())

    var body: some Scene {
        WindowGroup("Vibe Buddy") {
            ContentView()
                .environmentObject(state)
                .environmentObject(ble)
                .onAppear {
                    ble.bind(state: state)
                    // Bridge the macOS-only focus-gate signal up to AppState
                    // so ContentView can show "typing paused" when the
                    // session starts with focus on a non-editable control.
                    if let injector = ble.audio.textHandler as? TextInjector {
                        injector.onFocusChange = { [weak state] editable, desc in
                            state?.focusEditable = editable
                            state?.focusDescription = desc
                        }
                    }
                }
        }
        .defaultSize(width: 520, height: 380)
        .windowResizability(.contentSize)
    }
}
