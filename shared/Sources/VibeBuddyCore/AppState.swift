import Foundation
import Combine

// AppState is the single source of truth for the UI. Everything the view
// renders reads from here. BLEController + AudioStreamer mutate these on
// the main actor as events arrive off CoreBluetooth / STT callback queues.
//
// The flags here are the *union* of what either platform might surface;
// individual platforms simply ignore the ones that don't apply (iOS for
// example never sets accessibilityTrusted because it has no equivalent).
@MainActor
public final class AppState: ObservableObject {
    public enum LinkStatus: Equatable {
        case idle              // waiting for Bluetooth to power on
        case scanning
        case connecting(String)
        case connected(String) // device name
        case failed(String)
    }

    public struct LinkParams: Equatable {
        public var phy: String = "?"
        public var mtu: Int = 0
        public init(phy: String = "?", mtu: Int = 0) {
            self.phy = phy
            self.mtu = mtu
        }
    }

    public struct AudioSession: Equatable {
        public var active: Bool
        public var bytes: Int
        public var gaps: Int
        public var sampleRate: Int
        public var startedAt: Date
        public init(active: Bool, bytes: Int, gaps: Int, sampleRate: Int, startedAt: Date) {
            self.active = active
            self.bytes = bytes
            self.gaps = gaps
            self.sampleRate = sampleRate
            self.startedAt = startedAt
        }
    }

    @Published public var link: LinkStatus = .idle
    @Published public var linkParams = LinkParams()
    @Published public var lastJSON: String = ""
    @Published public var session: AudioSession? = nil
    @Published public var totalSessions: Int = 0
    @Published public var bluetoothPoweredOn: Bool = false
    @Published public var lastDumpPath: String? = nil

    // ASR / injection state
    @Published public var sttStatus: String = "idle"
    @Published public var partialText: String = ""
    @Published public var finalText: String = ""
    @Published public var asrError: String = ""
    @Published public var accessibilityTrusted: Bool = false
    @Published public var configMissing: Bool = false

    public init() {}
}
