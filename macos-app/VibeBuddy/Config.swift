import Foundation

// XDG_CONFIG_HOME/vibe-buddy/config.json (falls back to ~/.config).
// Phase 1 doesn't have a settings UI; the file is the single source of
// truth for Doubao SAUC credentials.
struct Config {
    let appID: String
    let accessToken: String
    let resourceID: String

    static let defaultResourceID = "volc.bigasr.sauc.duration"

    static func configURL() -> URL {
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"],
           !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config", isDirectory: true)
        }
        return base.appendingPathComponent("vibe-buddy/config.json")
    }

    static func load() -> Config? {
        let url = configURL()
        guard let data = try? Data(contentsOf: url) else {
            NSLog("[config] missing: %@", url.path)
            return nil
        }
        struct Raw: Decodable {
            let app_id: String
            let access_token: String
            let resource_id: String?
        }
        do {
            let raw = try JSONDecoder().decode(Raw.self, from: data)
            return Config(
                appID: raw.app_id,
                accessToken: raw.access_token,
                resourceID: raw.resource_id ?? Config.defaultResourceID
            )
        } catch {
            NSLog("[config] parse failed: %@", String(describing: error))
            return nil
        }
    }
}
