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
                .onAppear { ble.bind(state: state) }
        }
        .defaultSize(width: 520, height: 380)
        .windowResizability(.contentSize)
    }
}
