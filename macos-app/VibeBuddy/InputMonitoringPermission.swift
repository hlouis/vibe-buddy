import Foundation
import IOKit.hid
import VibeBuddyCore

// Thin wrapper around macOS 10.15+ IOHID access APIs for the Input
// Monitoring TCC service. We use these instead of "try CGEvent.tapCreate
// and see what happens" because:
//
//   1. Failed tapCreate calls don't always register the app in the
//      Privacy → Input Monitoring panel — the user can be left with
//      "我去哪儿打开权限？没有 VibeBuddy 这一项啊" puzzlement.
//
//   2. IOHIDRequestAccess is the documented entry point: it pops the
//      system prompt AND inserts the app into the privacy panel even
//      if the user dismisses the prompt. After that, granting is just
//      a toggle in System Settings.
//
//   3. We can poll IOHIDCheckAccess on app activation to auto-recover
//      when the user grants permission outside the app, instead of
//      requiring a manual "重试" click.
enum InputMonitoringPermission {

    static func check() -> AppState.MicAuth {
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        switch access {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied:  return .denied
        case kIOHIDAccessTypeUnknown: return .notDetermined
        default:                      return .unknown
        }
    }

    // Returns true synchronously iff already granted. If not granted,
    // shows the system prompt (which adds VibeBuddy to System Settings →
    // Privacy → Input Monitoring) and returns false. The user then
    // either flips the toggle right then or comes back later — either
    // way, the app shows up in the panel.
    @discardableResult
    static func request() -> Bool {
        return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
}
