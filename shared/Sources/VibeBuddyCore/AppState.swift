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

    // Audio source the user has selected. The macOS host writes this
    // through AudioSourceCoordinator; iOS leaves it at .bluetooth (its
    // only supported source). Surfaced here so ContentView can read it
    // without depending on macOS-only types.
    public enum AudioSource: String, Equatable, CaseIterable {
        case bluetooth   // M5Stack VibeBuddy device over BLE
        case mic         // System microphone + global hotkey PTT
    }

    public enum MicAuth: Equatable {
        case unknown
        case granted
        case denied
        case notDetermined
    }

    @Published public var audioSource: AudioSource = .bluetooth
    @Published public var hotkeyHint: String = "按住 Right Option ⌥ 说话（短按取消）"
    @Published public var hotkeyEnabled: Bool = false
    @Published public var hotkeyError: String = ""
    @Published public var micAuth: MicAuth = .unknown
    @Published public var micRunning: Bool = false
    // Input Monitoring (kIOHIDRequestTypeListenEvent) is a separate
    // TCC service from Accessibility — required for our CGEventTap to
    // observe Right Option key edges. Tracked independently so the UI
    // can show three distinct stages (unknown → prompted → granted)
    // and react to grants made outside the app (poll on focus regain).
    @Published public var inputMonitoringAuth: MicAuth = .unknown

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

    // macOS-only: snapshotted at the start of each session by the
    // FocusGate. When focusEditable is false, the macOS TextInjector
    // suppresses keystroke injection (avoids the funk-sound when typing
    // into non-editable focused controls). iOS leaves both fields at
    // their defaults — its PasteboardHandler is unaffected.
    @Published public var focusEditable: Bool = true
    @Published public var focusDescription: String = ""

    public init() {}
}
