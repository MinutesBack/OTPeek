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

/// Preset servers, plus the wording setup needs to explain itself.
///
/// The credential question is where people abandon mail setup: "app password"
/// means nothing on its own, and being asked for one right after a normal
/// password field looks like a trick. Each provider therefore carries its own
/// plain-language reason and the exact steps to get one.
struct Provider {
    let key: String
    let label: String
    let host: String
    let port: Int
    let auth: AuthKind
    /// One line under the provider picker.
    let help: String
    let credentialURL: String?
    /// Letter shown in the tile beside the provider name.
    let monogram: String
    /// Tile colour, in the provider's own colour family.
    let tintHex: String
    /// Answers "why can't I just use my normal password?"
    let why: String
    /// Numbered steps for getting the credential.
    let steps: [String]

    var needsAppPassword: Bool { auth == .password && credentialURL != nil }

    static let all: [Provider] = [
        Provider(key: "gmail", label: "Gmail / Google Workspace",
                 host: "imap.gmail.com", port: 993, auth: .password,
                 help: "Google needs a one-off App Password, not your normal one.",
                 credentialURL: "https://myaccount.google.com/apppasswords",
                 monogram: "G", tintHex: "#EA4335",
                 why: "Google stopped letting apps sign in with your normal password. "
                    + "An App Password is a separate 16-character password that only works "
                    + "for mail. Your real password is never typed here, and you can revoke "
                    + "the App Password at any time without changing it.",
                 steps: [
                    "Turn on 2-Step Verification in your Google account, if it isn't already.",
                    "Open the App passwords page and create one called OTPeek.",
                    "Copy the 16 characters Google shows you and paste them above.",
                 ]),
        Provider(key: "outlook", label: "Outlook / Microsoft 365",
                 host: "outlook.office365.com", port: 993, auth: .xoauth2,
                 help: "Signs in through your browser — no password is typed here.",
                 credentialURL: nil,
                 monogram: "O", tintHex: "#0F6CBD",
                 why: "Microsoft no longer allows password sign-in for mail apps at all, so "
                    + "OTPeek sends you to Microsoft's own sign-in page instead. It never "
                    + "sees your password — only a token you can revoke from your account.",
                 steps: []),
        Provider(key: "icloud", label: "iCloud Mail",
                 host: "imap.mail.me.com", port: 993, auth: .password,
                 help: "Apple needs an app-specific password, not your Apple Account one.",
                 credentialURL: "https://account.apple.com",
                 monogram: "i", tintHex: "#3D8BF2",
                 why: "Apple doesn't let apps sign in with your Apple Account password. "
                    + "An app-specific password works only for this one app, and revoking it "
                    + "leaves your Apple Account untouched.",
                 steps: [
                    "Sign in at account.apple.com.",
                    "Under Sign-In and Security, choose App-Specific Passwords.",
                    "Create one called OTPeek and paste it above.",
                 ]),
        Provider(key: "fastmail", label: "Fastmail",
                 host: "imap.fastmail.com", port: 993, auth: .password,
                 help: "Fastmail needs an app password with IMAP access.",
                 credentialURL: "https://app.fastmail.com/settings/security/apps",
                 monogram: "F", tintHex: "#0067B9",
                 why: "Fastmail keeps your main password for the website and issues separate "
                    + "app passwords for mail apps, so each one can be revoked on its own.",
                 steps: [
                    "Open Settings, then Privacy & Security, then Integrations.",
                    "Create a new app password with IMAP access.",
                    "Paste it above.",
                 ]),
        Provider(key: "yahoo", label: "Yahoo Mail",
                 host: "imap.mail.yahoo.com", port: 993, auth: .password,
                 help: "Yahoo needs an app password from your account security page.",
                 credentialURL: "https://login.yahoo.com/account/security",
                 monogram: "Y", tintHex: "#6001D2",
                 why: "Yahoo blocks mail apps from using your normal password. An app "
                    + "password works only for mail and can be revoked separately.",
                 steps: [
                    "Open your Yahoo account security page.",
                    "Choose Generate app password.",
                    "Paste it above.",
                 ]),
        Provider(key: "custom", label: "Other IMAP mailbox",
                 host: "", port: 993, auth: .password,
                 help: "Enter the IMAP server your provider documents.",
                 credentialURL: nil,
                 monogram: "✉", tintHex: "#5C5F7E",
                 why: "Some providers accept your normal password here; others issue a "
                    + "separate app password. Your provider's help pages will say which.",
                 steps: []),
    ]
}
