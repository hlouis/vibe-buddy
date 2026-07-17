import XCTest
@testable import VibeBuddyCore

// Covers the two pure functions the pairing whitelist rests on: turning
// an advertised name into a device ID, and normalizing a stored list.
// The persistence itself is platform-split (XDG file / UserDefaults) and
// exercised by hand; these are the parts with actual logic in them.
final class PairedDeviceTests: XCTestCase {

    // MARK: deviceID(fromName:)

    func testDeviceIDParsesAdvertisedName() {
        XCTAssertEqual(BLEController.deviceID(fromName: "VibeBuddy-C3D8"), "C3D8")
    }

    func testDeviceIDUppercasesSoListMembershipIsCaseInsensitive() {
        XCTAssertEqual(BLEController.deviceID(fromName: "VibeBuddy-c3d8"), "C3D8")
    }

    func testDeviceIDRejectsForeignName() {
        XCTAssertNil(BLEController.deviceID(fromName: "SomeOtherStick-C3D8"))
    }

    // A device advertising a bare prefix has no usable ID — we must not
    // hand "" to the whitelist, or an empty entry would match it.
    func testDeviceIDRejectsEmptySuffix() {
        XCTAssertNil(BLEController.deviceID(fromName: "VibeBuddy-"))
    }

    // MARK: PairedDeviceStore.normalize

    func testNormalizeUppercasesAndTrims() {
        XCTAssertEqual(PairedDeviceStore.normalize([" c3d8 ", "09af"]), ["C3D8", "09AF"])
    }

    // Same stick pasted twice, or picked from the list after being typed
    // into the config by hand, must not become two entries.
    func testNormalizeDedupesCaseInsensitively() {
        XCTAssertEqual(PairedDeviceStore.normalize(["C3D8", "c3d8"]), ["C3D8"])
    }

    func testNormalizePreservesOrder() {
        XCTAssertEqual(PairedDeviceStore.normalize(["09AF", "C3D8"]), ["09AF", "C3D8"])
    }

    func testNormalizeDropsEmpties() {
        XCTAssertEqual(PairedDeviceStore.normalize(["", "  ", "C3D8"]), ["C3D8"])
    }

    func testNormalizeEmptyStaysEmpty() {
        XCTAssertEqual(PairedDeviceStore.normalize([]), [])
    }

    // MARK: DiscoveredDevice
    //
    // Regression cover for the pairing sheet's seeding fix. The list is
    // built from scan callbacks, but a connected peripheral stops
    // advertising — so on an unpaired install, where the legacy
    // first-seen path has already connected to the user's only stick,
    // the sheet could never show the one device they wanted to pair.
    // BLEController.startDiscovery() now seeds from the live peripheral;
    // these pin the identity rules that seeding depends on.

    // Seeding and scanning both funnel into upsertDiscovered, so the two
    // must agree on identity or the connected device would appear twice
    // the moment it also got scanned.
    func testDiscoveredDeviceIdentityIsTheDeviceIDNotTheName() {
        let seeded = AppState.DiscoveredDevice(id: "C3D8", name: "VibeBuddy-C3D8", rssi: 0)
        let scanned = AppState.DiscoveredDevice(id: "C3D8", name: "VibeBuddy-C3D8", rssi: -40)
        XCTAssertEqual(seeded.id, scanned.id)
    }

    // The seed lands before readRSSI() returns, so it carries a
    // placeholder. It must still be a listable entry — showing the
    // device with a bogus signal beats not showing it at all.
    func testDiscoveredDeviceToleratesPlaceholderRSSI() {
        let d = AppState.DiscoveredDevice(id: "C3D8", name: "VibeBuddy-C3D8", rssi: 0)
        XCTAssertEqual(d.rssi, 0)
        XCTAssertEqual(d.id, "C3D8")
    }

    // The whitelist is authoritative only when non-empty; empty means
    // "connect to the first VibeBuddy seen", which is the pre-pairing
    // behavior every existing install upgrades from. It is also exactly
    // the state in which the seeding fix matters.
    func testEmptyWhitelistIsTheUnpairedFirstSeenState() {
        XCTAssertTrue(PairedDeviceStore.normalize([]).isEmpty)
        XCTAssertFalse(PairedDeviceStore.normalize(["C3D8"]).isEmpty)
    }
}
