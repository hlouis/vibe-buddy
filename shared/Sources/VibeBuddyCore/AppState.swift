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

    // A Vibe Buddy seen during a pairing scan. `id` is the XXXX suffix
    // the user can read off the device screen; rssi refreshes as long as
    // the pairing sheet is open (we scan with allowDuplicates there).
    public struct DiscoveredDevice: Identifiable, Equatable {
        public let id: String       // "C3D8"
        public let name: String     // "VibeBuddy-C3D8"
        public var rssi: Int
        public init(id: String, name: String, rssi: Int) {
            self.id = id
            self.name = name
            self.rssi = rssi
        }
    }

    public struct AudioSession: Equatable {
        public var active: Bool
        // Payload bytes accepted from the audio source. NOTE the unit is
        // codec-dependent: raw PCM for .pcm, compressed Opus for .opus.
        // Never derive a duration from this — see `durationSec`.
        public var bytes: Int
        public var gaps: Int
        public var sampleRate: Int
        public var startedAt: Date
        // Wall-clock seconds, stamped by AudioStreamer at each emit — so
        // it freezes at the right value once the session ends rather
        // than growing off startedAt forever. The UI used to divide
        // `bytes` by the PCM byte rate instead, which silently became
        // ~12x short the moment BLE sessions started carrying Opus.
        public var durationSec: TimeInterval
        // What `bytes` is counting, and what the dump file actually is.
        public var codec: AudioStreamer.Codec
        public init(active: Bool, bytes: Int, gaps: Int, sampleRate: Int,
                    startedAt: Date, durationSec: TimeInterval = 0,
                    codec: AudioStreamer.Codec = .pcm) {
            self.active = active
            self.bytes = bytes
            self.gaps = gaps
            self.sampleRate = sampleRate
            self.startedAt = startedAt
            self.durationSec = durationSec
            self.codec = codec
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
    @Published public var micModeReady: Bool = false
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

    // Device pairing. An empty pairedDeviceIDs means "unpaired" and we
    // fall back to connecting to whatever Vibe Buddy shows up first —
    // the behavior every existing install has today. Once the list is
    // non-empty it is authoritative and unlisted devices are ignored.
    @Published public var pairedDeviceIDs: [String] = []
    @Published public var discoveredDevices: [DiscoveredDevice] = []
    @Published public var discovering: Bool = false

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

    // iPad-only: tracks whether the NavigationSplitView's sidebar is
    // visible. Used by the floating PTT orb to decide whether to show
    // itself — the orb only appears when the in-sidebar mic button is
    // hidden (sidebar collapsed). iPhone never reads this; macOS leaves
    // it at the default.
    @Published public var sidebarVisible: Bool = true

    public init() {}
}
