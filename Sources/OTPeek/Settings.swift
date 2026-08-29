import Foundation

struct HUDSettings: Codable {
    var autoCopy: Bool = false
    var timeoutSeconds: Double = 45
    var playSound: Bool = true

    init(autoCopy: Bool = false, timeoutSeconds: Double = 45, playSound: Bool = true) {
        self.autoCopy = autoCopy
        self.timeoutSeconds = timeoutSeconds
        self.playSound = playSound
    }

    /// Missing keys fall back to the default rather than failing the whole
    /// decode — see the note on AppSettings.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        autoCopy = try values.decodeIfPresent(Bool.self, forKey: .autoCopy) ?? false
        timeoutSeconds = try values.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 45
        playSound = try values.decodeIfPresent(Bool.self, forKey: .playSound) ?? true
    }
}

struct AppSettings: Codable {
    var accounts: [Account] = []
    var smsEnabled: Bool = true
    var hud: HUDSettings = HUDSettings()
    /// Anything older than this when first seen is ignored, so launching the
    /// app never dumps a week of old codes on screen.
    var maxAgeMinutes: Int = 10
    var historySize: Int = 12
    /// Set when someone dismisses the Full Disk Access invitation for good.
    var declinedFullDiskAccess: Bool = false

    init() {}

    /// Decoded key by key, with each missing key falling back to its default.
    ///
    /// The synthesised decoder fails the entire decode when a key is absent,
    /// which means adding any new setting would make every existing config
    /// unreadable — silently discarding the mailboxes someone had already
    /// configured. Decoding leniently keeps old files working.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try values.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        smsEnabled = try values.decodeIfPresent(Bool.self, forKey: .smsEnabled) ?? true
        hud = try values.decodeIfPresent(HUDSettings.self, forKey: .hud) ?? HUDSettings()
        maxAgeMinutes = try values.decodeIfPresent(Int.self, forKey: .maxAgeMinutes) ?? 10
        historySize = try values.decodeIfPresent(Int.self, forKey: .historySize) ?? 12
        declinedFullDiskAccess = try values.decodeIfPresent(
            Bool.self, forKey: .declinedFullDiskAccess) ?? false
    }
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
