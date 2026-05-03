import Foundation

// PTT events flow into AudioStreamer regardless of where they came from.
// Three sources speak this vocabulary today:
//
//   1. BLE JSON control frames from the M5Stack device
//      ({"type":"audio","event":"start|stop|cancel"}) — translated by
//      BLEController/AudioStreamer.handleControl().
//   2. The macOS HotKeyPTTTrigger (CGEventTap on Right Option), used in
//      mic mode when no Bluetooth device is connected.
//   3. Tests / future sources (menu-bar button, Stream Deck, etc.).
//
// The 350 ms short-press → cancel rule lives on the trigger side, so by
// the time AudioStreamer sees the event it's already classified.
public enum PTTEvent: Sendable, Equatable {
    case start(sampleRate: Int)
    case stop
    case cancel
}

@MainActor
public protocol PTTTrigger: AnyObject {
    var onEvent: ((PTTEvent) -> Void)? { get set }
    func enable() throws
    func disable()
}
