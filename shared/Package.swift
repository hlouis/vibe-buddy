// swift-tools-version: 5.9
import PackageDescription

// Cross-platform core for Vibe Buddy. Holds everything that doesn't touch
// the host UI framework: BLE, audio framing, Doubao ASR, gzip, app-state
// view-model and the TextHandler abstraction. Both the macOS app (which
// supplies a CGEvent-based text injector) and the iOS app (which supplies
// a UIPasteboard-based handler) link this package as their single source
// of business logic.
let package = Package(
    name: "VibeBuddyCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v16),
    ],
    products: [
        .library(name: "VibeBuddyCore", targets: ["VibeBuddyCore"]),
    ],
    targets: [
        .target(name: "VibeBuddyCore", path: "Sources/VibeBuddyCore"),
    ]
)
