import SwiftUI
import VibeBuddyCore

@main
struct VibeBuddyApp: App {
    @StateObject private var state = AppState()
    @StateObject private var pasteboard: PasteboardHandler
    @StateObject private var ble: BLEController

    @MainActor
    init() {
        // Keep one PasteboardHandler shared between the BLE pipeline and
        // the SwiftUI view: ContentView reads it as an EnvironmentObject
        // for live transcript display, and BLEController → AudioStreamer
        // pushes ASR updates through the same instance via the
        // TextHandler protocol. App.init runs on the main thread already
        // so the @MainActor annotation is just making that explicit so
        // we can construct the @MainActor-isolated handlers right here.
        let pb = PasteboardHandler()
        _pasteboard = StateObject(wrappedValue: pb)
        _ble = StateObject(wrappedValue: BLEController(textHandler: pb))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .environmentObject(ble)
                .environmentObject(pasteboard)
                .onAppear { ble.bind(state: state) }
        }
    }
}
