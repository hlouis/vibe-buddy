import Foundation
import UIKit
import AVFoundation
import VibeBuddyCore

// iOS counterpart to macOS's AudioSourceCoordinator. Same job: switch
// between BLE and system-microphone PTT, gate the AudioStreamer source.
// Different glue:
//
//   • No CGEventTap → no "Input Monitoring" permission to manage.
//     The PTT trigger is just a SwiftUI button so enable() always
//     succeeds once mic permission is granted.
//
//   • AVAudioSession must be configured before the engine starts —
//     handled inside MicCaptureController.start() with #if os(iOS).
//     Interruption handling (phone calls) is set up here.
//
//   • Backgrounding teardown is driven by VibeBuddyApp's scenePhase
//     observer, which already calls ble.audio.cancelSession() on
//     phase != .active. We extend that path to also stop mic capture
//     so the engine releases the audio HW.
@MainActor
final class AudioSourceCoordinator: ObservableObject {

    let ble: BLEController
    let pttTrigger: ButtonPTTTrigger
    private let mic: MicCaptureController
    private weak var state: AppState?
    private var interruptionObserver: NSObjectProtocol?

    init(ble: BLEController) {
        self.ble = ble
        self.mic = MicCaptureController(audio: ble.audio)
        self.pttTrigger = ButtonPTTTrigger()
        self.pttTrigger.onEvent = { [weak self] event in
            self?.handlePTT(event)
        }
    }

    deinit {
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func bind(state: AppState) {
        self.state = state
        state.audioSource = .bluetooth
        state.micAuth = MicCaptureController.permission
        state.hotkeyHint = "按住下方按钮说话（短按取消）"

        // Interruption handling: phone call, Siri, alarm — anything that
        // takes the audio HW away from us. AVAudioSession posts .began
        // when the interruption starts; we cancel any in-flight session
        // and stop the engine so we don't fight for the resource. We do
        // NOT auto-resume on .ended — by then the user knows recording
        // was lost; making them re-press the button is honest UX.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }
    }

    // Called by VibeBuddyApp on scenePhase != .active. AudioStreamer's
    // existing cancel takes care of any open session; here we tear down
    // the trigger and force-release the engine in case a press was
    // in flight when we got backgrounded.
    func handleAppBackgrounded() {
        guard let state, state.audioSource == .mic else { return }
        NSLog("[coord] app backgrounded — disabling mic trigger")
        pttTrigger.disable()
        mic.stop()  // idempotent; covers mid-press backgrounding
        state.micModeReady = false
        state.hotkeyEnabled = false
    }

    // Re-arm the trigger when the user returns to the app. Engine
    // itself stays off until next PTT press — same on-demand model
    // as cold start.
    func handleAppForegrounded() {
        guard let state, state.audioSource == .mic else { return }
        if !state.micModeReady {
            Task { await activateMic() }
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

    func openMicSettings() {
        // iOS lumps every per-app permission under the app's settings
        // bundle. UIApplication.openSettingsURLString takes the user
        // straight to VibeBuddy's pane, where Microphone is the
        // relevant toggle.
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: setup / teardown per source

    private func teardown(current: AppState.AudioSource) {
        // Cancel any session in flight; AudioStreamer's `active` guard
        // handles re-entrancy but we want a clean slate for the new source.
        ble.audio.cancelSession()
        switch current {
        case .bluetooth:
            // Leave BLE running; its frames hit a no-op streamer until
            // a new session starts. Disconnecting on every toggle would
            // make the user re-pair after every mode switch.
            break
        case .mic:
            pttTrigger.disable()
            mic.stop()
            state?.hotkeyEnabled = false
            state?.micModeReady = false
        }
    }

    private func setup(_ source: AppState.AudioSource) async {
        switch source {
        case .bluetooth:
            // Nothing to do — BLEController is always-on. If the device
            // isn't connected the existing scanning/idle UI takes over.
            break
        case .mic:
            await activateMic()
        }
    }

    private func activateMic() async {
        guard let state else { return }

        // 1. Microphone permission. iOS 17+/macOS 14+ recommended API.
        var auth = MicCaptureController.permission
        if auth == .notDetermined {
            let granted = await MicCaptureController.requestPermission()
            auth = granted ? .granted : .denied
        }
        state.micAuth = auth
        guard auth == .granted else {
            state.hotkeyError = "需要麦克风权限"
            return
        }
        state.hotkeyError = ""

        // 2. Arm the button trigger. enable() can't fail on iOS (no
        //    OS-level resource to acquire) — kept in a do/try to mirror
        //    the macOS path and tolerate future trigger types.
        //
        //    The audio engine is NOT started here. We start it on each
        //    PTT press in handlePTT(.start) and tear it down on release
        //    so the iOS orange mic indicator only lights up while the
        //    user is actually holding the button.
        //
        //    That costs real audio: the tap delivers nothing for ~220 ms
        //    after start(), and those 220 ms of speech are gone. An
        //    earlier version of this comment claimed AudioStreamer's
        //    400 ms STT warmup "covered" it — it does not, and cannot.
        //    That window only delays opening the Doubao socket; it
        //    cannot buffer audio the hardware never captured. What
        //    actually absorbs the gap is the user's own reaction time
        //    between pressing and speaking. Press-and-speak-instantly
        //    clips the first syllable, and that is the accepted price of
        //    not leaving the orange dot lit for the whole session.
        //
        //    prime() below keeps that gap at 220 ms instead of the
        //    ~1.5 s an unprimed first press would cost. Measured on
        //    macOS; iOS is not yet hardware-verified (see
        //    docs/hardware-debug.md) but the CoreAudio HAL warmup it
        //    pays for is the same mechanism.
        mic.prime()
        do {
            try pttTrigger.enable()
            state.hotkeyEnabled = true
            state.micModeReady = true   // "mic mode ready", not "engine on"
        } catch {
            state.hotkeyEnabled = false
            state.micModeReady = false
            state.hotkeyError = error.localizedDescription
        }
    }

    // MARK: PTT -> AudioStreamer
    //
    // Engine lifecycle is bound to the press edge, not the mode. Order
    // matters:
    //   • on .start, bring up the engine first; if it fails we don't
    //     start a session that has no audio source.
    //   • on .stop / .cancel, drain the streamer first (it flushes the
    //     last chunk and closes the STT session), then release the
    //     engine. Tap callbacks already in flight hit `active == false`
    //     in ingestPCM and get dropped — at most one ~21 ms tap buffer.

    private func handlePTT(_ event: PTTEvent) {
        switch event {
        case .start:
            do {
                try mic.start()
            } catch {
                state?.hotkeyError = "麦克风启动失败：\(error.localizedDescription)"
                return
            }
            // Mic mode: tailTrimMs = 0 so we don't clip the user's last
            // syllable when they release the button.
            ble.audio.handlePTT(event, tailTrimMs: 0)
        case .stop, .cancel:
            ble.audio.handlePTT(event, tailTrimMs: 0)
            mic.stop()
        }
    }

    // MARK: interruption

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else {
            return
        }
        switch type {
        case .began:
            NSLog("[coord] audio session interrupted — cancelling")
            ble.audio.cancelSession()
            pttTrigger.disable()
            mic.stop()  // idempotent; only does work if a press was in flight
            state?.micModeReady = false
            state?.hotkeyEnabled = false
        case .ended:
            // Don't auto-resume. User decides when they're ready.
            NSLog("[coord] interruption ended — waiting for user")
        @unknown default:
            break
        }
    }
}
