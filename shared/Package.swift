// swift-tools-version: 6.2
import PackageDescription

// Cross-platform core for Vibe Buddy. Holds everything that doesn't touch
// the host UI framework: BLE, audio framing, Doubao ASR, gzip, app-state
// view-model and the TextHandler abstraction. Both the macOS app (which
// supplies a CGEvent-based text injector) and the iOS app (which supplies
// a UIPasteboard-based handler) link this package as their single source
// of business logic.
//
// Tools-version is 6.2 because that's the minimum that knows about the
// `.iOS(.v26)` deployment target enum (introduced with the iOS 26 SDK).
// We keep the per-target language mode pinned to Swift 5, though,
// because the iOS app needs WebPage from the iOS 26 SDK but the BLE /
// audio code in this package was written before Swift 6's strict-
// concurrency rules and isn't worth churning right now — Apple's own
// CoreBluetooth APIs ship non-Sendable types (CBPeripheral, CBService)
// across nonisolated delegate boundaries, which is unfixable below the
// SDK level.
let package = Package(
    name: "VibeBuddyCore",
    platforms: [
        .macOS(.v14),
        // iOS 26 minimum so the iOS app can use the native SwiftUI
        // WebView/WebPage API (WWDC 2025) instead of the legacy
        // WKWebView+UIViewRepresentable bridge — the legacy path crashes
        // on iOS 26 inside UIGestureRecognizer's delayed-touch handling
        // (FB-reported, no SDK-side workaround), and the new WebPage is
        // a first-class SwiftUI Observable so we also delete a pile of
        // KVO/delegate scaffolding.
        .iOS(.v26),
    ],
    products: [
        .library(name: "VibeBuddyCore", targets: ["VibeBuddyCore"]),
    ],
    targets: [
        .target(
            name: "VibeBuddyCore",
            path: "Sources/VibeBuddyCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VibeBuddyCoreTests",
            dependencies: ["VibeBuddyCore"],
            path: "Tests/VibeBuddyCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
