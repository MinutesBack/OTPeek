import Foundation

/// Keeps one mailbox connected and reports new messages.
///
/// Prefers IDLE so a code appears about a second after the mail lands, and
/// falls back to polling on servers that do not offer it. Reconnects with
/// exponential backoff, because laptops sleep and networks drop.
final class IMAPWatcher {

    typealias MessageHandler = (IncomingMessage) -> Void
    typealias StatusHandler = (String, SourceState, String) -> Void
    typealias CredentialProvider = (Account) -> String?

    private static let idleRearmSeconds: TimeInterval = 600
    private static let pollFallbackSeconds: TimeInterval = 15
    private static let fetchLimitBytes = 262_144

    let account: Account

    private let maxAgeMinutes: Int
    private let credentialProvider: CredentialProvider
    private let onMessage: MessageHandler
    private let onStatus: StatusHandler

    private var thread: Thread?
    private let stopFlag = Flag()
    private var client: IMAPClient?
    private var lastUID = 0

    init(account: Account, maxAgeMinutes: Int,
         credentialProvider: @escaping CredentialProvider,
         onMessage: @escaping MessageHandler,
         onStatus: @escaping StatusHandler) {
        self.account = account
        self.maxAgeMinutes = maxAgeMinutes
        self.credentialProvider = credentialProvider
        self.onMessage = onMessage
        self.onStatus = onStatus
    }

    // MARK: - Lifecycle

    func start() {
        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "imap-\(account.id)"
        thread.stackSize = 512 * 1024
        self.thread = thread
        thread.start()
    }

    func stop() {
        stopFlag.set(true)
        client?.disconnect()
    }

    private func loop() {
        var backoff: TimeInterval = 5

        while !stopFlag.get() {
            do {
                try connect()
                backoff = 5
                try watch()
            } catch {
                if stopFlag.get() { return }
                onStatus(account.id, .error, error.localizedDescription)
                Log.write("[error] \(account.label): \(error.localizedDescription)")
                client?.disconnect()
                client = nil

                let wake = Date().addingTimeInterval(backoff)
                while Date() < wake && !stopFlag.get() { Thread.sleep(forTimeInterval: 0.5) }
                backoff = min(backoff * 2, 300)
            }
        }
    }

    // MARK: - Connection

    private func connect() throws {
        onStatus(account.id, .connecting, "\(account.label) · connecting…")

        guard let secret = credentialProvider(account) else {
            if account.auth == .password, case .failure(let reason) = Keychain.read(account.id) {
                switch reason {
                case .notStored:
                    throw IMAPClient.IMAPError.authenticationFailed(
                        "Password not found in the Keychain — re-add this mailbox in Settings")
                case .blocked(let status):
                    // Usually a rebuilt app: the Keychain entry was saved by a
                    // build with a different signature, so macOS withholds it.
                    throw IMAPClient.IMAPError.authenticationFailed(
                        "macOS would not release the saved password (\(status)). "
                        + "Choose Allow if prompted, or re-add this mailbox.")
                }
            }
            throw IMAPClient.IMAPError.authenticationFailed(
                "Could not sign in — re-add this mailbox in Settings")
        }

        let client = IMAPClient(host: account.host, port: account.port)
        try client.connect()

        switch account.auth {
        case .password:
            try client.login(user: account.user, password: secret)
        case .xoauth2:
            try client.authenticateXOAUTH2(user: account.user, token: secret)
        }

        try client.select(account.folder)
        // Baseline at the newest message so startup stays quiet.
        lastUID = try client.highestUID()
        self.client = client

        let mode = client.supportsIDLE ? "push" : "polling"
        onStatus(account.id, .ok, "\(account.label) · \(mode)")
        Log.write("[ok] \(account.label): connected (\(mode)), baseline uid \(lastUID)")
    }

    private func watch() throws {
        guard let client else { return }

        while !stopFlag.get() {
            var changed = true
            if client.supportsIDLE {
                changed = try client.idle(rearmAfter: Self.idleRearmSeconds) { [weak self] in
                    self?.stopFlag.get() ?? true
                }
            } else {
                let wake = Date().addingTimeInterval(Self.pollFallbackSeconds)
                while Date() < wake && !stopFlag.get() { Thread.sleep(forTimeInterval: 0.5) }
            }
            if stopFlag.get() { return }
            if changed { try fetchNew(client) }
        }
    }

    private func fetchNew(_ client: IMAPClient) throws {
        let uids = try client.uids(after: lastUID)
        guard !uids.isEmpty else { return }

        let cutoff = Date().addingTimeInterval(-Double(maxAgeMinutes) * 60)

        // Only the newest few matter; a large backlog means we were asleep.
        for uid in uids.suffix(10) {
            lastUID = max(lastUID, uid)
            guard let raw = try client.fetchMessage(uid: uid, maxBytes: Self.fetchLimitBytes) else {
                continue
            }

            let part = MIME.parse(raw)
            let subject = MIME.decodeWords(part.header("Subject") ?? "")
            let sender = MIME.decodeWords(part.header("From") ?? "")

            var received = Date()
            if let dateHeader = part.header("Date"), let parsed = Self.parseDate(dateHeader) {
                received = parsed
            }
            guard received >= cutoff else { continue }

            let bodies = MIME.bestBodies(part)
            onMessage(IncomingMessage(
                source: "email",
                account: account.label,
                accountID: account.id,
                sender: sender,
                subject: subject,
                body: bodies.html.isEmpty ? bodies.plain : bodies.html,
                plainAlternative: bodies.plain.isEmpty ? nil : bodies.plain,
                isHTML: !bodies.html.isEmpty,
                received: received))
        }
    }

    private static let dateFormatters: [DateFormatter] = {
        ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z",
         "EEE, d MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm Z"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }
    }()

    private static func parseDate(_ raw: String) -> Date? {
        // Strip a trailing "(UTC)"-style comment, which the formats reject.
        var text = raw.trimmingCharacters(in: .whitespaces)
        if let paren = text.firstIndex(of: "(") {
            text = String(text[text.startIndex..<paren]).trimmingCharacters(in: .whitespaces)
        }
        for formatter in dateFormatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

/// Thread-safe boolean.
final class Flag {
    private let lock = NSLock()
    private var value = false

    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
