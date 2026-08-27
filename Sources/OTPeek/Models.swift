import Foundation

enum AuthKind: String, Codable, CaseIterable {
    case password
    case xoauth2
}

struct Account: Codable, Identifiable, Hashable {
    var id: String
    var label: String
    var user: String
    var host: String
    var port: Int
    var auth: AuthKind
    var folder: String = "INBOX"
    /// Microsoft only: the Entra application this device signs in through.
    var clientID: String?
    var tenant: String?
}

/// A message from any source, before extraction.
struct IncomingMessage {
    var source: String          // "sms" | "email"
    var account: String
    var accountID: String?
    var sender: String
    var subject: String
    var body: String
    var plainAlternative: String?
    var isHTML: Bool
    var received: Date
}

/// A message that produced something worth showing.
struct Hit: Identifiable {
    let id = UUID()
    var code: String?
    var link: String?
    var source: String
    var account: String
    var sender: String
    var senderShort: String
    var subject: String
    var received: Date
    var confidence: Double
}

/// Preset servers so setup only asks for an address and a password.
struct Provider {
    let key: String
    let label: String
    let host: String
    let port: Int
    let auth: AuthKind
    let help: String
    let credentialURL: String?

    static let all: [Provider] = [
        Provider(key: "gmail", label: "Gmail / Google Workspace",
                 host: "imap.gmail.com", port: 993, auth: .password,
                 help: "Needs 2-Step Verification, then an App Password — not your normal password.",
                 credentialURL: "https://myaccount.google.com/apppasswords"),
        Provider(key: "outlook", label: "Outlook / Microsoft 365",
                 host: "outlook.office365.com", port: 993, auth: .xoauth2,
                 help: "Signs in through your browser. Microsoft no longer allows password-based IMAP.",
                 credentialURL: nil),
        Provider(key: "icloud", label: "iCloud Mail",
                 host: "imap.mail.me.com", port: 993, auth: .password,
                 help: "Needs an app-specific password from your Apple Account page.",
                 credentialURL: "https://account.apple.com"),
        Provider(key: "fastmail", label: "Fastmail",
                 host: "imap.fastmail.com", port: 993, auth: .password,
                 help: "Create an app password with IMAP access in Fastmail settings.",
                 credentialURL: "https://app.fastmail.com/settings/security/apps"),
        Provider(key: "yahoo", label: "Yahoo Mail",
                 host: "imap.mail.yahoo.com", port: 993, auth: .password,
                 help: "Needs an app password from Yahoo account security.",
                 credentialURL: "https://login.yahoo.com/account/security"),
        Provider(key: "custom", label: "Other IMAP server",
                 host: "", port: 993, auth: .password,
                 help: "Enter the IMAP host your provider documents.",
                 credentialURL: nil),
    ]
}
