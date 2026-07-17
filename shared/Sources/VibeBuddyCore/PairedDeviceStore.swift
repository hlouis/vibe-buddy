import Foundation

// Persists the set of paired Vibe Buddy device IDs.
//
// Deliberately NOT part of Config: Config models the Doubao credentials
// and its load() returns nil when they're absent. Folding the paired
// list in there would mean "user hasn't filled in their ASR token" also
// wipes "which stick is mine", which are unrelated facts with unrelated
// lifetimes.
//
// A device ID is the XXXX suffix of the advertised name VibeBuddy-XXXX,
// derived firmware-side from the last two bytes of the BT MAC
// (see firmware/src/main.cpp). It is stable across hosts and reinstalls,
// unlike CoreBluetooth's peripheral.identifier which is per-host — so a
// list pairs cleanly against what the user reads off the device screen.
//
// Storage mirrors Config's split: XDG file on macOS, UserDefaults on iOS.
public enum PairedDeviceStore {

    #if os(macOS)
    public static func storeURL() -> URL {
        Config.configDir().appendingPathComponent("devices.json")
    }
    #endif

    public static func load() -> [String] {
        #if os(macOS)
        guard let data = try? Data(contentsOf: storeURL()) else { return [] }
        guard let ids = try? JSONDecoder().decode([String].self, from: data) else {
            NSLog("[devices] parse failed, treating as unpaired")
            return []
        }
        return normalize(ids)
        #else
        let ids = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return normalize(ids)
        #endif
    }

    public static func save(_ ids: [String]) {
        let ids = normalize(ids)
        #if os(macOS)
        let url = storeURL()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(ids)
            try data.write(to: url, options: .atomic)
            NSLog("[devices] saved %d paired -> %@", ids.count, url.path)
        } catch {
            NSLog("[devices] save failed: %@", String(describing: error))
        }
        #else
        UserDefaults.standard.set(ids, forKey: defaultsKey)
        NSLog("[devices] saved %d paired", ids.count)
        #endif
    }

    // Uppercase + dedupe, order preserved. The IDs are hex read off a
    // screen and typed into a config by hand as often as they're picked
    // from the list, so we don't want "c3d8" and "C3D8" to be two
    // different devices.
    static func normalize(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    #if os(iOS)
    private static let defaultsKey = "VibeBuddyPairedDevices"
    #endif
}
