import Foundation
import AppKit
import AVFoundation
import Combine
import VibeBuddyCore

// AudioSourceCoordinator owns the two PTT pipelines and switches between
// them. It does not touch AudioStreamer's internals — it just feeds
// PTTEvents and (in mic mode) raw PCM. The streamer remains source-
// agnostic.
//
// Bluetooth mode (default):
//   - BLEController scans + connects + dispatches audio frames + JSON
//     control frames. AudioStreamer sees the BLE click, applies its
//     200 ms tail trim, and ASR runs as before. This path is
//     untouched — preserving the existing user experience verbatim.
//
// Mic mode:
//   - MicCaptureController taps AVAudioEngine and streams 16 kHz Int16
//     PCM into AudioStreamer.ingestPCM(). The engine is brought up on
//     each PTT press and torn down on release so the macOS status-bar
//     mic indicator is only lit while the user is actually holding the
//     hotkey. tailTrimMs is forced to 0 here because there is no button
//     click to clip.
//
// Switching cancels any in-flight session before swapping pipelines so
// AudioStreamer's `active` invariant is never violated.
@MainActor
final class AudioSourceCoordinator: ObservableObject {

    let ble: BLEController
    private let mic: MicCaptureController
    private let hotkey: HotKeyPTTTrigger
    private weak var state: AppState?
    private var didBecomeActiveObserver: NSObjectProtocol?

    init(ble: BLEController) {
        self.ble = ble
        self.mic = MicCaptureController(audio: ble.audio)
        self.hotkey = HotKeyPTTTrigger()
        self.hotkey.onEvent = { [weak self] event in
            self?.handleHotkeyPTT(event)
        }
    }

    deinit {
        if let obs = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func bind(state: AppState) {
        self.state = state
        state.audioSource = .bluetooth
        state.micAuth = Self.readMicAuth()
        state.inputMonitoringAuth = InputMonitoringPermission.check()

        // When the user comes back from System Settings (e.g. after
        // toggling Input Monitoring on for VibeBuddy), the app window
        // gets a didBecomeActive notification. Re-poll and auto-enable
        // hotkey if we're in mic mode and were waiting on this.
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissionsOnFocus() }
        }
    }

    private func refreshPermissionsOnFocus() {
        guard let state else { return }
        let micNow = Self.readMicAuth()
        let imNow  = InputMonitoringPermission.check()
        if state.micAuth != micNow            { state.micAuth = micNow }
        if state.inputMonitoringAuth != imNow { state.inputMonitoringAuth = imNow }

        // Auto-enable hotkey if we were blocked on Input Monitoring
        // and the user just granted it.
        if state.audioSource == .mic,
           state.micRunning,
           !state.hotkeyEnabled,
           imNow == .granted {
            NSLog("[coord] input monitoring granted out-of-band — enabling hotkey")
            do {
                try hotkey.enable()
                state.hotkeyEnabled = true
                state.hotkeyError = ""
            } catch {
                state.hotkeyError = error.localizedDescription
            }
        }
    }

    // MARK: public API

    func switchTo(_ source: AppState.AudioSource) {
        guard let state, state.audioSource != source else { return }
        NSLog("[coord] switching audio source: %@ -> %@",
              state.audioSource.rawValue, source.rawValue)
        teardown(current: state.audioSource)
        state.audioSource = source
        Task { await setup(source) }
    }

    func retryHotkey() {
        guard let state, state.audioSource == .mic else { return }
        do {
            try hotkey.enable()
            state.hotkeyEnabled = true
            state.hotkeyError = ""
        } catch {
            state.hotkeyEnabled = false
            state.hotkeyError = error.localizedDescription
        }
    }

    func openMicSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: setup / teardown per source

    private func teardown(current: AppState.AudioSource) {
        // Always cancel any session in flight — AudioStreamer guards
        // re-entrancy on `active`, but we want a clean slate.
        ble.audio.cancelSession()
        switch current {
        case .bluetooth:
            // Leave BLE running; its frames will simply hit a no-op
            // streamer (audio.active == false) until a new session
            // starts. Disconnecting on every toggle would be jarring.
            break
        case .mic:
            hotkey.disable()
            mic.stop()
            state?.hotkeyEnabled = false
            state?.micRunning = false
        }
    }

    private func setup(_ source: AppState.AudioSource) async {
        switch source {
        case .bluetooth:
            // Nothing to do — BLEController is always-on. If the device
            // isn't connected, the existing scanning/idle UI takes over.
            break
        case .mic:
            await activateMic()
        }
    }

    private func activateMic() async {
        guard let state else { return }

        // 1. Microphone permission (NSMicrophoneUsageDescription).
        var auth = Self.readMicAuth()
        if auth == .notDetermined {
            let granted = await MicCaptureController.requestPermission()
            auth = granted ? .granted : .denied
        }
        state.micAuth = auth
        guard auth == .granted else {
            state.hotkeyError = "需要麦克风权限"
            return
        }

        // 2. Input Monitoring permission. Check first so we know what
        //    UI to show; if not yet granted, IOHIDRequestAccess pops
        //    the system prompt AND adds VibeBuddy to System Settings →
        //    Privacy → Input Monitoring (where the user can flip the
        //    toggle at their leisure). We then attempt tapCreate;
        //    refreshPermissionsOnFocus() will retry it automatically
        //    once the user comes back from System Settings.
        var imAuth = InputMonitoringPermission.check()
        if imAuth != .granted {
            NSLog("[coord] requesting input monitoring (current=%@)", "\(imAuth)")
            InputMonitoringPermission.request()
            // Re-check synchronously — request() returns true iff
            // already granted; nothing changes mid-call otherwise.
            imAuth = InputMonitoringPermission.check()
        }
        state.inputMonitoringAuth = imAuth

        // 3. Hook up the global hotkey. If Input Monitoring isn't
        //    granted yet, tapCreate will fail and we surface the error
        //    + a deep-link button. The auto-recover path in
        //    refreshPermissionsOnFocus() picks it up later.
        //
        //    The audio engine is NOT started here — it gets brought up
        //    lazily on each PTT press in handleHotkeyPTT(.start) and
        //    torn down on release, so the status-bar mic indicator
        //    only lights up while the user is actually holding the
        //    hotkey. The 100–300 ms warmup overlaps AudioStreamer's
        //    400 ms STT warmup window, so first-syllable audio is
        //    not perceptibly clipped.
        do {
            try hotkey.enable()
            state.hotkeyEnabled = true
            state.micRunning = true   // "mic mode ready", not "engine on"
            state.hotkeyError = ""
        } catch {
            state.hotkeyEnabled = false
            state.micRunning = false
            state.hotkeyError = imAuth == .granted
                ? error.localizedDescription
                : "需要「输入监控」权限。请在系统设置中为 VibeBuddy 打开后回到此窗口，会自动启用。"
        }
    }

    // MARK: hotkey -> AudioStreamer
    //
    // Engine lifecycle is bound to the press edge, not the mode. Order
    // matters:
    //   • on .start, bring up the engine first; if it fails we don't
    //     start a session that has no audio source.
    //   • on .stop / .cancel, drain the streamer first (it flushes the
    //     last chunk and closes the STT session), then release the
    //     engine. Tap callbacks already in flight hit `active == false`
    //     in ingestPCM and get dropped — at most one ~21 ms tap buffer.

    private func handleHotkeyPTT(_ event: PTTEvent) {
        switch event {
        case .start:
            do {
                try mic.start()
            } catch {
                state?.hotkeyError = "麦克风启动失败：\(error.localizedDescription)"
                return
            }
            // Mic mode: tailTrimMs = 0 so we don't clip the user's last
            // syllable when they release the hotkey.
            ble.audio.handlePTT(event, tailTrimMs: 0)
        case .stop, .cancel:
            ble.audio.handlePTT(event, tailTrimMs: 0)
            mic.stop()
        }
    }

    // MARK: helpers

    // The shared MicCaptureController.permission already maps to
    // AppState.MicAuth — this used to translate from AVAuthorizationStatus
    // back when macOS used AVCaptureDevice directly. Kept as a one-liner
    // wrapper so call sites read symmetrically with InputMonitoringPermission.check().
    private static func readMicAuth() -> AppState.MicAuth {
        MicCaptureController.permission
    }
}
