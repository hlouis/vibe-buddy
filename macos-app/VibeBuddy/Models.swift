import Foundation
import Combine

// AppState is the single source of truth for the UI. Everything the view
// renders reads from here. The BLEController mutates these on the main
// actor as events arrive off CoreBluetooth's callback queue.
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

    // Last PCM file path we dumped a session to. Step 5 just writes to
    // disk so we can verify parity with the Python dumper; step 6 swaps
    // this out for the streaming ASR pipeline.
    @Published var lastDumpPath: String? = nil
}
