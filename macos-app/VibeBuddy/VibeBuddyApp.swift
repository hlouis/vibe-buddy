import SwiftUI

@main
struct VibeBuddyApp: App {
    @StateObject private var state = AppState()
    @StateObject private var ble = BLEController()

    init() {
        // Wire BLE -> AppState once. The controller owns the CBCentralManager
        // and handles frame dispatch; AppState is the view model the UI reads.
    }

    var body: some Scene {
        WindowGroup("Vibe Buddy") {
            ContentView()
                .environmentObject(state)
                .environmentObject(ble)
                .onAppear { ble.bind(state: state) }
        }
        .defaultSize(width: 520, height: 380)
        .windowResizability(.contentSize)
    }
}
