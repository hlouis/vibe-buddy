import Foundation

// Doubao SAUC credentials. Where they live differs per platform:
//
//   • macOS: $XDG_CONFIG_HOME/vibe-buddy/config.json (falls back to
//     ~/.config). Easy to provision from the README's heredoc snippet
//     and survives app reinstalls.
//
//   • iOS:   UserDefaults under the "VibeBuddyConfig" key. The iOS app
//     ships an in-app settings sheet that writes here — there is no
//     filesystem outside the app sandbox we could place a config in.
//     A future revision should migrate these into the Keychain; for
//     phase 2 UserDefaults is enough to get the iOS build running.
//
// STTService and the rest of the package only ever calls Config.load();
// the storage detail is hidden behind that one entry point.
public struct Config {
    public let appID: String
    public let accessToken: String
    public let resourceID: String

    public static let defaultResourceID = "volc.bigasr.sauc.duration"

    public init(appID: String, accessToken: String, resourceID: String = Config.defaultResourceID) {
        self.appID = appID
        self.accessToken = accessToken
        self.resourceID = resourceID
    }

    // Human-readable description of where to look / how to provision
    // the config. Surfaced in UI ("Doubao config missing — see README").
    public static var sourceDescription: String {
        #if os(macOS)
        return configURL().path
        #else
        return "Settings → Doubao credentials"
        #endif
    }

    public static func load() -> Config? {
        #if os(macOS)
        return loadFromXDG()
        #else
        return loadFromDefaults()
        #endif
    }

    // MARK: macOS — XDG config file

    #if os(macOS)
    public static func configURL() -> URL {
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

    private static func loadFromXDG() -> Config? {
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
    #endif

    // MARK: iOS — UserDefaults

    #if os(iOS)
    private static let defaultsKey = "VibeBuddyConfig"

    private static func loadFromDefaults() -> Config? {
        guard let dict = UserDefaults.standard.dictionary(forKey: defaultsKey),
              let appID = dict["app_id"] as? String, !appID.isEmpty,
              let token = dict["access_token"] as? String, !token.isEmpty
        else { return nil }
        let resource = (dict["resource_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? Config.defaultResourceID
        return Config(appID: appID, accessToken: token, resourceID: resource)
    }

    public static func save(appID: String, accessToken: String, resourceID: String) {
        UserDefaults.standard.set([
            "app_id": appID,
            "access_token": accessToken,
            "resource_id": resourceID,
        ], forKey: defaultsKey)
    }

    public static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
    #endif
}
