import XCTest
@testable import VibeBuddyCore

// Config has two backends compiled per-platform: a JSON file under
// XDG_CONFIG_HOME on macOS, and UserDefaults on iOS. These tests
// pin down the load/save shape on each platform without leaking state
// into the real user defaults / config dir.
final class ConfigTests: XCTestCase {

    // MARK: macOS — XDG file backend

    #if os(macOS)
    private var tempXDG: URL!
    private var savedXDG: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempXDG = FileManager.default.temporaryDirectory
            .appendingPathComponent("vbtest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempXDG, withIntermediateDirectories: true)
        savedXDG = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        setenv("XDG_CONFIG_HOME", tempXDG.path, 1)
    }

    override func tearDownWithError() throws {
        if let saved = savedXDG {
            setenv("XDG_CONFIG_HOME", saved, 1)
        } else {
            unsetenv("XDG_CONFIG_HOME")
        }
        try? FileManager.default.removeItem(at: tempXDG)
        try super.tearDownWithError()
    }

    func testConfigURLUsesXDG() {
        let url = Config.configURL()
        XCTAssertTrue(url.path.hasPrefix(tempXDG.path),
                      "expected configURL to live under XDG_CONFIG_HOME=\(tempXDG.path), got \(url.path)")
        XCTAssertTrue(url.path.hasSuffix("vibe-buddy/config.json"))
    }

    func testLoadReturnsNilWhenMissing() {
        XCTAssertNil(Config.load())
    }

    func testLoadParsesValidJSON() throws {
        try writeConfig(#"""
        { "app_id": "abc", "access_token": "tkn", "resource_id": "res-1" }
        """#)
        let cfg = Config.load()
        XCTAssertNotNil(cfg)
        XCTAssertEqual(cfg?.appID, "abc")
        XCTAssertEqual(cfg?.accessToken, "tkn")
        XCTAssertEqual(cfg?.resourceID, "res-1")
    }

    func testLoadDefaultsResourceIDWhenMissing() throws {
        try writeConfig(#"""
        { "app_id": "x", "access_token": "y" }
        """#)
        let cfg = Config.load()
        XCTAssertEqual(cfg?.resourceID, Config.defaultResourceID)
    }

    func testLoadReturnsNilOnMalformedJSON() throws {
        try writeConfig("not even json")
        XCTAssertNil(Config.load())
    }

    private func writeConfig(_ json: String) throws {
        let url = Config.configURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try json.write(to: url, atomically: true, encoding: .utf8)
    }
    #endif

    // MARK: iOS — UserDefaults backend

    #if os(iOS)
    private let key = "VibeBuddyConfig"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func testLoadReturnsNilWhenEmpty() {
        XCTAssertNil(Config.load())
    }

    func testSaveAndLoadRoundtrip() {
        Config.save(appID: "appX", accessToken: "tkn", resourceID: "res")
        let cfg = Config.load()
        XCTAssertNotNil(cfg)
        XCTAssertEqual(cfg?.appID, "appX")
        XCTAssertEqual(cfg?.accessToken, "tkn")
        XCTAssertEqual(cfg?.resourceID, "res")
    }

    func testSaveDefaultsBlankResourceToConstant() {
        // Caller responsibility (settings UI does the substitution),
        // but verify that explicitly storing an empty resource_id falls
        // back to the default when loaded.
        Config.save(appID: "a", accessToken: "t", resourceID: "")
        let cfg = Config.load()
        XCTAssertEqual(cfg?.resourceID, Config.defaultResourceID)
    }

    func testClearRemovesConfig() {
        Config.save(appID: "a", accessToken: "t", resourceID: "r")
        XCTAssertNotNil(Config.load())
        Config.clear()
        XCTAssertNil(Config.load())
    }

    func testLoadIgnoresEmptyAppID() {
        UserDefaults.standard.set([
            "app_id": "", "access_token": "t", "resource_id": "r",
        ], forKey: key)
        XCTAssertNil(Config.load())
    }
    #endif
}
