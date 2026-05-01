import Foundation
import Combine

// User-editable persistence for SiteKeyPolicy. Same shape as
// BookmarkStore: load on init from UserDefaults, fall through to
// SiteKeyPolicy.defaults on a fresh install, save after every
// mutation. The catch-all "*" entry is never deleted; the detail
// editor also forbids changing its hostSuffix, but this layer
// enforces the same rule defensively in case a future caller
// bypasses the UI.
//
// Sort order: longer hostSuffix first, "*" pinned last. That way the
// linear scan in SiteKeyPolicy.resolve picks the most specific match
// without the user having to think about ordering — they add a
// bookmark for "kimi.moonshot.cn" and it automatically wins over the
// catch-all.
@MainActor
final class PolicyStore: ObservableObject {

    @Published private(set) var items: [SiteKeyPolicy]

    static let defaultsKey = "VibeBuddyKeyPolicies_v1"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = PolicyStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([SiteKeyPolicy].self, from: data),
           !decoded.isEmpty {
            self.items = Self.sorted(Self.ensuringCatchAll(decoded))
        } else {
            self.items = Self.sorted(SiteKeyPolicy.defaults)
        }
    }

    // MARK: mutation

    func add(_ policy: SiteKeyPolicy) {
        var next = items
        next.append(policy)
        items = Self.sorted(next)
        save()
    }

    func update(_ policy: SiteKeyPolicy) {
        guard let i = items.firstIndex(where: { $0.id == policy.id }) else { return }
        // Don't let an update mutate the sentinel hostSuffix away
        // from "*" — the editor blocks this in the UI but the model
        // layer enforces it too.
        var sanitized = policy
        if items[i].isCatchAll { sanitized.hostSuffix = "*" }
        var next = items
        next[i] = sanitized
        items = Self.sorted(next)
        save()
    }

    func remove(_ id: SiteKeyPolicy.ID) {
        guard let target = items.first(where: { $0.id == id }) else { return }
        if target.isCatchAll { return }   // never remove the fallback
        items.removeAll { $0.id == id }
        save()
    }

    func resetToPresets() {
        items = Self.sorted(SiteKeyPolicy.defaults)
        save()
    }

    // MARK: helpers

    // Most specific (longest hostSuffix) first; "*" pinned last so
    // resolve() picks it only when no real domain matches.
    static func sorted(_ raw: [SiteKeyPolicy]) -> [SiteKeyPolicy] {
        raw.sorted { a, b in
            if a.isCatchAll { return false }
            if b.isCatchAll { return true }
            if a.hostSuffix.count != b.hostSuffix.count {
                return a.hostSuffix.count > b.hostSuffix.count
            }
            return a.hostSuffix < b.hostSuffix
        }
    }

    // Defensive: if a corrupted persisted blob lacks a "*" entry,
    // splice the default catch-all back in. The editor forbids
    // creating this state but a manual UserDefaults edit could.
    private static func ensuringCatchAll(_ raw: [SiteKeyPolicy]) -> [SiteKeyPolicy] {
        if raw.contains(where: { $0.isCatchAll }) { return raw }
        var withFallback = raw
        if let stockFallback = SiteKeyPolicy.defaults.first(where: { $0.isCatchAll }) {
            withFallback.append(stockFallback)
        } else {
            withFallback.append(SiteKeyPolicy(hostSuffix: "*", onBtnAClick: .insertNewline))
        }
        return withFallback
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: key)
        }
    }
}
