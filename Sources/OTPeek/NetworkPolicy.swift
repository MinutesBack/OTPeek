import Foundation

/// The single gate every outbound connection passes through.
///
/// The guarantee people need before typing a mail password into a downloaded
/// app is that it cannot phone home. Rather than asking for trust, OTPeek
/// enforces it: a connection is permitted only to a mail server the user
/// entered themselves, or to Microsoft's sign-in endpoint for Outlook
/// accounts. Everything else throws before a socket is opened.
///
/// Two things make this checkable rather than a claim:
///   * every attempt, allowed or refused, is written to the log, so the hosts
///     the app talks to can be read off disk;
///   * `run-tests.sh` fails the build if networking APIs appear in any file
///     other than the two that route through here.
enum NetworkPolicy {

    enum PolicyError: LocalizedError {
        case blocked(String)

        var errorDescription: String? {
            switch self {
            case .blocked(let host):
                return "Refused to connect to \(host): it is not a mail server you configured."
            }
        }
    }

    /// The only host not derived from the user's own configuration. Outlook
    /// accounts cannot use a password, so sign-in has to go through Microsoft.
    static let signInHost = "login.microsoftonline.com"

    private static let lock = NSLock()
    private static var temporaryAllowance: Set<String> = []
    private static var seen: [(host: String, when: Date)] = []

    /// Hosts this build is currently able to reach.
    static func allowedHosts() -> Set<String> {
        var hosts: Set<String> = [signInHost]
        for account in SettingsStore.shared.settings.accounts {
            hosts.insert(account.host.lowercased())
        }
        lock.lock()
        hosts.formUnion(temporaryAllowance)
        lock.unlock()
        return hosts
    }

    /// Throws unless `host` is a mail server the user configured.
    static func check(_ host: String) throws {
        let normalised = host.lowercased()
        guard allowedHosts().contains(normalised) else {
            Log.write("[refused] connection to \(host) — not a configured mail server")
            throw PolicyError.blocked(host)
        }
        lock.lock()
        seen.removeAll { $0.host == normalised }
        seen.append((normalised, Date()))
        if seen.count > 20 { seen.removeFirst(seen.count - 20) }
        lock.unlock()
        Log.write("[net] \(normalised)")
    }

    /// Hosts contacted this session, most recent last.
    static func recentConnections() -> [(host: String, when: Date)] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    /// Permits one host while a new mailbox is being verified, before it has
    /// been saved to the configuration. Scoped to the call, never left open.
    static func whileVerifying<T>(_ host: String, _ body: () throws -> T) rethrows -> T {
        let normalised = host.lowercased()
        lock.lock(); temporaryAllowance.insert(normalised); lock.unlock()
        defer {
            lock.lock()
            temporaryAllowance.remove(normalised)
            lock.unlock()
        }
        return try body()
    }
}
