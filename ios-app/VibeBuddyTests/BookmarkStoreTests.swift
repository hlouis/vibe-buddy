import XCTest
@testable import VibeBuddy

@MainActor
final class BookmarkStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "com.yourname.vibebuddy.tests.bookmarks"

    override func setUp() {
        super.setUp()
        // Throw-away suite so test runs don't touch the user's real
        // bookmark list; reset on every test to start clean.
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() -> BookmarkStore {
        BookmarkStore(defaults: defaults, key: "items")
    }

    // MARK: seeding

    func testFreshStoreSeedsPresets() {
        let store = makeStore()
        XCTAssertEqual(store.items.count, BookmarkStore.presets.count)
        XCTAssertEqual(store.items.map(\.name), BookmarkStore.presets.map(\.name))
    }

    func testPresetsIncludeKeyAIChatSites() {
        // Tripwire: if anyone removes Claude / 豆包 / Kimi from the
        // seed list, this fails so they have to consciously update
        // the test rather than ship a broken default UX.
        let names = BookmarkStore.presets.map(\.name)
        XCTAssertTrue(names.contains("Claude"))
        XCTAssertTrue(names.contains("ChatGPT"))
        XCTAssertTrue(names.contains("豆包"))
        XCTAssertTrue(names.contains("Kimi"))
        XCTAssertTrue(names.contains("DeepSeek"))
        XCTAssertTrue(names.contains("通义"))
    }

    // MARK: add / remove / reset

    func testAddAppendsBookmark() {
        let store = makeStore()
        let initialCount = store.items.count
        store.add(name: "Notion AI", url: "https://www.notion.so")
        XCTAssertEqual(store.items.count, initialCount + 1)
        XCTAssertEqual(store.items.last?.name, "Notion AI")
        XCTAssertEqual(store.items.last?.url, "https://www.notion.so")
    }

    func testAddIgnoresBlanks() {
        let store = makeStore()
        let initial = store.items.count
        store.add(name: "", url: "https://x.com")
        store.add(name: "x", url: "")
        store.add(name: "  ", url: "https://y.com")
        XCTAssertEqual(store.items.count, initial)
    }

    func testRemoveDropsByID() {
        let store = makeStore()
        let target = store.items[0]
        store.remove(target.id)
        XCTAssertFalse(store.items.contains(where: { $0.id == target.id }))
        XCTAssertEqual(store.items.count, BookmarkStore.presets.count - 1)
    }

    func testResetToPresetsRestoresOriginalList() {
        let store = makeStore()
        store.items.removeAll()
        store.add(name: "Custom", url: "https://example.com")
        store.resetToPresets()
        XCTAssertEqual(store.items.count, BookmarkStore.presets.count)
        XCTAssertFalse(store.items.contains(where: { $0.name == "Custom" }))
    }

    // MARK: persistence

    func testAddPersistsAcrossInstances() {
        let store1 = makeStore()
        store1.add(name: "Mistral", url: "https://chat.mistral.ai")
        // A new store reading the same defaults must see the change.
        let store2 = makeStore()
        XCTAssertTrue(store2.items.contains(where: { $0.name == "Mistral" }))
    }

    func testRemovePersistsAcrossInstances() {
        let store1 = makeStore()
        let target = store1.items[0]
        store1.remove(target.id)
        let store2 = makeStore()
        XCTAssertFalse(store2.items.contains(where: { $0.id == target.id }))
    }

    func testResetPersistsAcrossInstances() {
        let store1 = makeStore()
        store1.items.removeAll()
        store1.resetToPresets()
        let store2 = makeStore()
        XCTAssertEqual(store2.items.count, BookmarkStore.presets.count)
    }
}
