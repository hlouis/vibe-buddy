import XCTest
@testable import VibeBuddy

// PolicyStore is the user-editable persistence layer for SiteKeyPolicy.
// Same shape as BookmarkStoreTests: throw-away UserDefaults suite per
// test, exercise add/update/remove/reset, plus the load-from-stored-
// data path. Sort order and the catch-all immutability rules are
// load-bearing — most of the tests exist to pin those down so a
// future refactor can't quietly drop them.
@MainActor
final class PolicyStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "com.yourname.vibebuddy.tests.policies"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() -> PolicyStore {
        PolicyStore(defaults: defaults, key: "items")
    }

    // MARK: seeding

    func testFreshStoreSeedsDefaults() {
        let store = makeStore()
        XCTAssertEqual(store.items.count, SiteKeyPolicy.defaults.count)
    }

    func testFreshStoreEndsWithCatchAll() {
        let store = makeStore()
        XCTAssertTrue(store.items.last?.isCatchAll ?? false,
                      "* must be sorted to the bottom of the list")
    }

    func testSortPutsLongerSuffixesAheadOfShorter() {
        // The product-level guarantee: a more specific host wins
        // resolution. Sort is what makes the linear scan correct.
        let raw = [
            SiteKeyPolicy(hostSuffix: "*",                 onBtnAClick: .pressEnter),
            SiteKeyPolicy(hostSuffix: "ai.com",            onBtnAClick: .pressEnter),
            SiteKeyPolicy(hostSuffix: "chat.special.ai.com", onBtnAClick: .pressShiftEnter),
        ]
        let sorted = PolicyStore.sorted(raw)
        XCTAssertEqual(sorted[0].hostSuffix, "chat.special.ai.com")
        XCTAssertEqual(sorted[1].hostSuffix, "ai.com")
        XCTAssertTrue(sorted.last?.isCatchAll ?? false)
    }

    // MARK: add / update / remove / reset

    func testAddAppendsAndPersists() {
        let store1 = makeStore()
        let count = store1.items.count
        store1.add(SiteKeyPolicy(hostSuffix: "kimi.moonshot.cn", onBtnAClick: .pressEnter))
        XCTAssertEqual(store1.items.count, count + 1)
        let store2 = makeStore()
        XCTAssertTrue(store2.items.contains(where: { $0.hostSuffix == "kimi.moonshot.cn" }))
    }

    func testAddPlacesNewEntryBySuffixLength() {
        let store = makeStore()
        store.add(SiteKeyPolicy(hostSuffix: "doubao.com", onBtnAClick: .pressEnter))
        // "chat.deepseek.com" (17) > "doubao.com" (10) > "ai.com" etc.
        let suffixes = store.items.map(\.hostSuffix)
        let idxDoubao = suffixes.firstIndex(of: "doubao.com")!
        let idxLong = suffixes.firstIndex(of: "chat.deepseek.com")!
        XCTAssertLessThan(idxLong, idxDoubao,
                          "longer suffixes must sort ahead of shorter ones")
        XCTAssertEqual(suffixes.last, "*")
    }

    func testUpdatePreservesIDAndSwapsAction() {
        let store = makeStore()
        let target = store.items.first(where: { $0.hostSuffix == "chatgpt.com" })!
        var updated = target
        updated.onBtnAClick = .click(selector: "#send")
        store.update(updated)
        let after = store.items.first(where: { $0.id == target.id })
        XCTAssertNotNil(after)
        if case .click(let s) = after?.onBtnAClick {
            XCTAssertEqual(s, "#send")
        } else {
            XCTFail("update did not swap the action")
        }
    }

    func testUpdateCannotChangeCatchAllSuffix() {
        let store = makeStore()
        let star = store.items.first(where: { $0.isCatchAll })!
        var hijack = star
        hijack.hostSuffix = "evil.com"
        hijack.onBtnAClick = .click(selector: "body")
        store.update(hijack)
        let after = store.items.first(where: { $0.id == star.id })!
        XCTAssertEqual(after.hostSuffix, "*",
                       "the * sentinel must not be hijack-able into a regular row")
        // Action change still applies — it's only the hostSuffix
        // that's protected.
        if case .click(let s) = after.onBtnAClick {
            XCTAssertEqual(s, "body")
        } else {
            XCTFail("expected the action to still update")
        }
    }

    func testRemoveDropsByID() {
        let store = makeStore()
        let target = store.items.first(where: { !$0.isCatchAll })!
        store.remove(target.id)
        XCTAssertFalse(store.items.contains(where: { $0.id == target.id }))
    }

    func testRemoveRefusesToDeleteCatchAll() {
        let store = makeStore()
        let star = store.items.first(where: { $0.isCatchAll })!
        store.remove(star.id)
        XCTAssertTrue(store.items.contains(where: { $0.isCatchAll }),
                      "removing the catch-all must be a no-op so resolve() always has a fallback")
    }

    func testResetRestoresDefaults() {
        let store = makeStore()
        let count = store.items.count
        store.add(SiteKeyPolicy(hostSuffix: "extra.example.com", onBtnAClick: .pressEnter))
        XCTAssertEqual(store.items.count, count + 1)
        store.resetToPresets()
        XCTAssertEqual(store.items.count, SiteKeyPolicy.defaults.count)
        XCTAssertFalse(store.items.contains(where: { $0.hostSuffix == "extra.example.com" }))
    }

    // MARK: persistence

    func testEditedPolicyRoundTripsThroughUserDefaults() {
        let store1 = makeStore()
        let target = store1.items.first(where: { $0.hostSuffix == "chat.openai.com" })!
        var modified = target
        modified.onBtnAClick = .click(selector: "[data-testid='send-button']")
        store1.update(modified)

        let store2 = makeStore()
        let after = store2.items.first(where: { $0.id == target.id })
        XCTAssertNotNil(after, "id must survive Codable round-trip")
        if case .click(let s) = after?.onBtnAClick {
            XCTAssertEqual(s, "[data-testid='send-button']")
        } else {
            XCTFail("Codable lost the .click case")
        }
    }

    func testCorruptedStoredDataWithoutCatchAllStillProvidesOne() {
        // Defensive: someone manually edits UserDefaults to remove the
        // "*" entry. The store must splice a fallback back in so
        // resolve() can never return nil for unknown hosts.
        let onlyOne = [
            SiteKeyPolicy(hostSuffix: "x.com", onBtnAClick: .pressEnter)
        ]
        let data = try! JSONEncoder().encode(onlyOne)
        defaults.set(data, forKey: "items")
        let store = makeStore()
        XCTAssertTrue(store.items.contains(where: { $0.isCatchAll }))
    }

    func testEmptyStoredArrayFallsBackToDefaults() {
        // A persisted but empty array is treated as "first launch" —
        // we don't ship the user a useless empty list.
        let data = try! JSONEncoder().encode([SiteKeyPolicy]())
        defaults.set(data, forKey: "items")
        let store = makeStore()
        XCTAssertEqual(store.items.count, SiteKeyPolicy.defaults.count)
    }
}
