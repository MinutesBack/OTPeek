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
                 why: "Google stopped letting apps sign in with your normal password. An App Password is a separate 16-character password that only works for mail. Your real password is never typed here, and you can revoke the App Password at any time without changing it.",
                 steps: [
                    "Turn on 2-Step Verification in your Google account, if it isn't already.",
                    "Open the App passwords page and create one called OTPeek.",
                    "Copy the 16 characters Google shows you — OTPeek fills them in.",
                 ]),
        Provider(key: "outlookcom", label: "Outlook.com / Hotmail / Live",
                 host: "imap-mail.outlook.com", port: 993, auth: .password,
                 help: "Personal Microsoft accounts need an app password — no Azure setup.",
                 credentialURL: "https://account.live.com/proofs/AppPassword",
                 monogram: "O", tintHex: "#0078D4",
                 why: "Microsoft blocks normal passwords for mail apps, but personal accounts "
                    + "can still create an app password, which is far simpler than the sign-in "
                    + "that work accounts require. It works only for mail and can be revoked "
                    + "on its own.",
                 steps: [
                    "Turn on two-step verification for your Microsoft account, if it isn't on.",
                    "Open the app passwords page and create one.",
                    "Copy it — OTPeek fills it in.",
                 ]),
        Provider(key: "outlook", label: "Microsoft 365 (work or school)",
                 host: "outlook.office365.com", port: 993, auth: .xoauth2,
                 help: "Work and school accounts sign in through Microsoft. Needs a client ID.",
                 credentialURL: nil,
                 monogram: "O", tintHex: "#0F6CBD",
                 why: "Microsoft no longer allows password sign-in for mail apps, so OTPeek sends you to Microsoft's own sign-in page. It never sees your password — only a token you can revoke from your account.",
                 steps: []),
        Provider(key: "icloud", label: "iCloud Mail",
                 host: "imap.mail.me.com", port: 993, auth: .password,
                 help: "Apple needs an app-specific password, not your Apple Account one.",
                 credentialURL: "https://account.apple.com",
                 monogram: "i", tintHex: "#3D8BF2",
                 why: "Apple offers no browser sign-in for mail apps, so an app-specific password is the only way in. It works for this one app, and revoking it leaves your Apple Account untouched.",
                 steps: [
                    "Sign in at account.apple.com.",
                    "Under Sign-In and Security, choose App-Specific Passwords.",
                    "Create one called OTPeek — OTPeek fills it in when you copy it.",
                 ]),
        Provider(key: "proton", label: "Proton Mail (via Bridge)",
                 host: "127.0.0.1", port: 1143, auth: .password,
                 help: "Needs Proton Mail Bridge running. Uses the password Bridge shows you.",
                 credentialURL: "https://proton.me/mail/bridge",
                 monogram: "P", tintHex: "#6D4AFF",
                 why: "Proton encrypts mail end to end, so it offers no direct IMAP. Proton Mail Bridge runs on your Mac, decrypts locally and serves IMAP at 127.0.0.1 — nothing leaves the machine. Bridge requires a paid Proton plan.",
                 steps: [
                    "Install and sign in to Proton Mail Bridge.",
                    "Open Bridge, choose your account, then Mailbox details.",
                    "Copy the password Bridge shows — it is not your Proton password.",
                 ]),
        Provider(key: "yahoo", label: "Yahoo Mail",
                 host: "imap.mail.yahoo.com", port: 993, auth: .password,
                 help: "Yahoo needs an app password from your account security page.",
                 credentialURL: "https://login.yahoo.com/account/security",
                 monogram: "Y", tintHex: "#6001D2",
                 why: "Your provider does not let apps sign in with your normal password. An app password works only for mail and can be revoked on its own, without changing the password you actually use.",
                 steps: [
                    "Open your Yahoo account security page.",
                    "Choose Generate app password.",
                    "Copy it — OTPeek fills it in.",
                 ]),
        Provider(key: "fastmail", label: "Fastmail",
                 host: "imap.fastmail.com", port: 993, auth: .password,
                 help: "Fastmail needs an app password with IMAP access.",
                 credentialURL: "https://app.fastmail.com/settings/security/apps",
                 monogram: "F", tintHex: "#0067B9",
                 why: "Your provider does not let apps sign in with your normal password. An app password works only for mail and can be revoked on its own, without changing the password you actually use.",
                 steps: [
                    "Open Settings, then Privacy & Security, then Integrations.",
                    "Create a new app password with IMAP access.",
                    "Copy it — OTPeek fills it in.",
                 ]),
        Provider(key: "zoho", label: "Zoho Mail",
                 host: "imap.zoho.com", port: 993, auth: .password,
                 help: "Zoho needs an application-specific password.",
                 credentialURL: "https://accounts.zoho.com/home#security/apppassword",
                 monogram: "Z", tintHex: "#E42527",
                 why: "Your provider does not let apps sign in with your normal password. An app password works only for mail and can be revoked on its own, without changing the password you actually use.",
                 steps: [
                    "Open Zoho Accounts, then Security, then App Passwords.",
                    "Generate one for OTPeek.",
                    "Copy it — OTPeek fills it in.",
                 ]),
        Provider(key: "gmx", label: "GMX",
                 host: "imap.gmx.com", port: 993, auth: .password,
                 help: "Enable IMAP in GMX settings, then use your normal password.",
                 credentialURL: nil,
                 monogram: "X", tintHex: "#1C449B",
                 why: "This provider accepts your normal mailbox password over IMAP. It is stored in your Mac's Keychain and sent only to your provider. GMX requires IMAP access to be switched on in its own settings first.",
                 steps: []),
        Provider(key: "aol", label: "AOL Mail",
                 host: "imap.aol.com", port: 993, auth: .password,
                 help: "AOL needs an app password from your account security page.",
                 credentialURL: "https://login.aol.com/account/security",
                 monogram: "A", tintHex: "#0F69FF",
                 why: "Your provider does not let apps sign in with your normal password. An app password works only for mail and can be revoked on its own, without changing the password you actually use.",
                 steps: [
                    "Open your AOL account security page.",
                    "Choose Generate app password.",
                    "Copy it — OTPeek fills it in.",
                 ]),
        Provider(key: "orange", label: "Orange",
                 host: "imap.orange.fr", port: 993, auth: .password,
                 help: "Uses your normal Orange mail password.",
                 credentialURL: nil,
                 monogram: "O", tintHex: "#FF7900",
                 why: "This provider accepts your normal mailbox password over IMAP. It is stored in your Mac's Keychain and sent only to your provider.",
                 steps: []),
        Provider(key: "free", label: "Free",
                 host: "imap.free.fr", port: 993, auth: .password,
                 help: "Uses your normal Free mail password.",
                 credentialURL: nil,
                 monogram: "F", tintHex: "#CD1F2C",
                 why: "This provider accepts your normal mailbox password over IMAP. It is stored in your Mac's Keychain and sent only to your provider.",
                 steps: []),
        Provider(key: "sfr", label: "SFR",
                 host: "imap.sfr.fr", port: 993, auth: .password,
                 help: "Uses your normal SFR mail password.",
                 credentialURL: nil,
                 monogram: "S", tintHex: "#E2001A",
                 why: "This provider accepts your normal mailbox password over IMAP. It is stored in your Mac's Keychain and sent only to your provider.",
                 steps: []),
        Provider(key: "laposte", label: "La Poste",
                 host: "imap.laposte.net", port: 993, auth: .password,
                 help: "Uses your normal Laposte.net password.",
                 credentialURL: nil,
                 monogram: "L", tintHex: "#FFCC00",
                 why: "This provider accepts your normal mailbox password over IMAP. It is stored in your Mac's Keychain and sent only to your provider.",
                 steps: []),
        Provider(key: "custom", label: "Other IMAP mailbox",
                 host: "", port: 993, auth: .password,
                 help: "Enter the IMAP server your provider documents.",
                 credentialURL: nil,
                 monogram: "✉", tintHex: "#5C5F7E",
                 why: "Some providers accept your normal password here; others issue a separate app password. Your provider's help pages will say which.",
                 steps: []),
    ]
}
