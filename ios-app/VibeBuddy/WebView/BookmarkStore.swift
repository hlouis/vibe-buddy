import Foundation
import Combine

struct Bookmark: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var url: String
    var symbol: String   // SF Symbol used as a stand-in for a favicon
}

// User's bookmark list, persisted in UserDefaults. Seeded on first
// launch with the six AI chat sites we know work in a vanilla WKWebView
// (Gemini is intentionally absent — its Google login refuses to run in
// an embedded webview, so adding it would just frustrate the user).
@MainActor
final class BookmarkStore: ObservableObject {

    @Published var items: [Bookmark]

    static let defaultsKey = "VibeBuddyBookmarks_v1"

    // Backing store + key are injectable so tests can run against a
    // throw-away UserDefaults suite without polluting the user's real
    // bookmark list.
    private let defaults: UserDefaults
    private let key: String

    static let presets: [Bookmark] = [
        Bookmark(name: "Claude",   url: "https://claude.ai/new",         symbol: "sparkle"),
        Bookmark(name: "ChatGPT",  url: "https://chat.openai.com",       symbol: "bubble.left.and.text.bubble.right"),
        Bookmark(name: "豆包",     url: "https://www.doubao.com/chat",   symbol: "leaf"),
        Bookmark(name: "Kimi",     url: "https://kimi.moonshot.cn",      symbol: "moon.stars"),
        Bookmark(name: "DeepSeek", url: "https://chat.deepseek.com",     symbol: "magnifyingglass"),
        Bookmark(name: "通义",     url: "https://tongyi.aliyun.com",     symbol: "cloud"),
    ]

    init(defaults: UserDefaults = .standard, key: String = BookmarkStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) {
            self.items = decoded
        } else {
            self.items = Self.presets
        }
    }

    func add(name: String, url: String) {
        let normalized = name.trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty, !url.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        items.append(Bookmark(name: normalized, url: url, symbol: "bookmark"))
        save()
    }

    func remove(_ id: Bookmark.ID) {
        items.removeAll { $0.id == id }
        save()
    }

    func resetToPresets() {
        items = Self.presets
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: key)
        }
    }
}
