import Foundation

struct HUDSettings: Codable {
    var autoCopy: Bool = false
    var timeoutSeconds: Double = 45
    var playSound: Bool = true
}

struct AppSettings: Codable {
    var accounts: [Account] = []
    var smsEnabled: Bool = true
    var hud: HUDSettings = HUDSettings()
    /// Anything older than this when first seen is ignored, so launching the
    /// app never dumps a week of old codes on screen.
    var maxAgeMinutes: Int = 10
    var historySize: Int = 12
}

/// Reads and writes `~/Library/Application Support/OTPeek/config.json`.
///
/// A plain JSON file rather than UserDefaults so the configuration is
/// inspectable and portable. Passwords are never in it — see `Keychain`.
final class SettingsStore {
    static let shared = SettingsStore()

    private(set) var settings: AppSettings

    let directory: URL
    let url: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("OTPeek", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        directory = base
        url = base.appendingPathComponent("config.json")

        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        save()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
    }

    func reload() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        }
    }
}
