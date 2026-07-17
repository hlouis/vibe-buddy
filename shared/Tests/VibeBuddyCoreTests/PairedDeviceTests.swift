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
}
