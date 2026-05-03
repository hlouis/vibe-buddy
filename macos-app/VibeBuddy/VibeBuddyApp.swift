import SwiftUI
import Combine
import VibeBuddyCore

@main
struct VibeBuddyApp: App {
    @StateObject private var state = AppState()
    // BLE and the AudioSourceCoordinator share a single BLEController
    // instance — the coordinator drives mode switching, while BLE keeps
    // owning its CoreBluetooth stack. Both are constructed in init() so
    // we can wire the cross-dependency without building anything twice.
    @StateObject private var ble: BLEController
    @StateObject private var coord: AudioSourceCoordinator
    // Re-emits the front-app name to the device when the BLE link goes
    // from down -> ready, so the StickS3 gets an initial sync without
    // waiting for the user to switch apps after connecting.
    @State private var linkReadyCancellable: AnyCancellable?

    init() {
        let bleObj = BLEController(textHandler: TextInjector())
        _ble = StateObject(wrappedValue: bleObj)
        _coord = StateObject(wrappedValue: AudioSourceCoordinator(ble: bleObj))
    }

    var body: some Scene {
        WindowGroup("Vibe Buddy") {
            ContentView()
                .environmentObject(state)
                .environmentObject(ble)
                .environmentObject(coord)
                .onAppear {
                    ble.bind(state: state)
                    coord.bind(state: state)
                    // Bridge the macOS-only focus-gate signal up to AppState
                    // so ContentView can show "typing paused" when the
                    // session starts with focus on a non-editable control.
                    if let injector = ble.audio.textHandler as? TextInjector {
                        injector.onFocusChange = { [weak state] editable, desc in
                            state?.focusEditable = editable
                            state?.focusDescription = desc
                        }
                    }

                    // Front-app -> device. Push as a JSON line on the same
                    // RX characteristic the device uses for control frames.
                    FrontAppMonitor.shared.onChange = { [weak ble] name in
                        guard let ble else { return }
                        let escaped = jsonEscape(name)
                        let line = "{\"type\":\"front_app\",\"name\":\"\(escaped)\"}\n"
                        if let data = line.data(using: .utf8) {
                            ble.write(data)
                        }
                    }
                    FrontAppMonitor.shared.start()

                    // mtu transitions 0 -> non-zero exactly when the device
                    // sends its first {"type":"link",...} message, which
                    // means rxCharacteristic is bound and writes will land.
                    // Use that edge as the trigger to resend the current
                    // front-app value.
                    linkReadyCancellable = state.$linkParams
                        .map(\.mtu)
                        .removeDuplicates()
                        .filter { $0 > 0 }
                        .sink { _ in FrontAppMonitor.shared.resend() }
                }
        }
        .defaultSize(width: 520, height: 380)
        .windowResizability(.contentSize)

        // Standard macOS Settings window (Cmd+,). Lets the user manage
        // Doubao credentials without ever opening a terminal — see
        // SettingsView for scope rationale.
        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}

// Minimal JSON string escape — covers the only characters that can show
// up in a macOS app name and would corrupt the wire format. We're not
// pulling in JSONEncoder for a single string field.
private func jsonEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s {
        switch ch {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:   out.append(ch)
        }
    }
    return out
}
