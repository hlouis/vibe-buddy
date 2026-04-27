import Foundation
@testable import VibeBuddy
import VibeBuddyCore

// Test double for the TextHandler protocol. Records every call so
// assertion sites can verify dispatch without standing up real
// PasteboardHandler / WebViewInjector instances (which carry
// UIPasteboard side-effects and WKWebView dependencies).
@MainActor
final class MockTextHandler: TextHandler {

    enum Call: Equatable {
        case checkPermission
        case update(String)
        case reset
        case sendEnter
        case sendBackspaceChar
        case clearAll
        case rollback
    }

    private(set) var calls: [Call] = []
    var permissionResult: Bool = true
    var onPermissionRequired: (() -> Void)?

    func checkPermission() -> Bool {
        calls.append(.checkPermission)
        return permissionResult
    }
    func update(to newText: String) { calls.append(.update(newText)) }
    func reset()                    { calls.append(.reset) }
    func sendEnter()                { calls.append(.sendEnter) }
    func sendBackspaceChar()        { calls.append(.sendBackspaceChar) }
    func clearAll()                 { calls.append(.clearAll) }
    func rollback()                 { calls.append(.rollback) }

    func clear() { calls.removeAll() }
}
