import Foundation
import Combine

// AppState is the single source of truth for the UI. Everything the view
// renders reads from here. BLEController + AudioStreamer mutate these on
// the main actor as events arrive off CoreBluetooth / STT callback queues.
@MainActor
final class AppState: ObservableObject {
    enum LinkStatus: Equatable {
        case idle              // waiting for Bluetooth to power on
        case scanning
        case connecting(String)
        case connected(String) // device name
        case failed(String)
    }

    struct LinkParams: Equatable {
        var phy: String = "?"
        var mtu: Int = 0
    }

    struct AudioSession: Equatable {
        var active: Bool
        var bytes: Int
        var gaps: Int
        var sampleRate: Int
        var startedAt: Date
    }

    @Published var link: LinkStatus = .idle
    @Published var linkParams = LinkParams()
    @Published var lastJSON: String = ""
    @Published var session: AudioSession? = nil
    @Published var totalSessions: Int = 0
    @Published var bluetoothPoweredOn: Bool = false
    @Published var lastDumpPath: String? = nil

    // ASR / injection state
    @Published var sttStatus: String = "idle"
    @Published var partialText: String = ""
    @Published var finalText: String = ""
    @Published var asrError: String = ""
    @Published var accessibilityTrusted: Bool = false
    @Published var configMissing: Bool = false
}
