import Foundation
import Network

/// A small synchronous IMAP client.
///
/// Only what a code catcher needs: authenticate, select the inbox, learn which
/// messages are new, fetch them, and hold an IDLE so new mail arrives as a
/// push rather than on a poll. Written against NWConnection so TLS and
/// certificate validation come from the system.
final class IMAPClient {

    enum IMAPError: LocalizedError {
        case connectionFailed(String)
        case authenticationFailed(String)
        case protocolError(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .connectionFailed(let detail): return detail
            case .authenticationFailed(let detail): return detail
            case .protocolError(let detail): return detail
            case .timedOut: return "timed out"
            }
        }
    }

    private let host: String
    private let port: Int
    private let queue = DispatchQueue(label: "com.otpeek.imap")

    private var connection: NWConnection?
    private let condition = NSCondition()
    private var buffer = Data()
    private var streamClosed = false
    private var streamError: Error?
    private var tagCounter = 0

    private(set) var capabilities: Set<String> = []

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// True only for addresses that cannot leave this machine.
    static func isLoopback(_ host: String) -> Bool {
        let normalised = host.lowercased()
        if normalised == "localhost" || normalised == "::1" { return true }
        if normalised == "127.0.0.1" { return true }
        // The whole 127.0.0.0/8 range is loopback.
        let parts = normalised.split(separator: ".")
        guard parts.count == 4, parts[0] == "127" else { return false }
        return parts.allSatisfy { Int($0).map { $0 >= 0 && $0 <= 255 } ?? false }
    }

    // MARK: - Connection

    func connect(timeout: TimeInterval = 30) throws {
        // Refuses anything that is not a mail server the user configured.
        try NetworkPolicy.check(host)

        let tls = NWProtocolTLS.Options()
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(timeout)

        // Local bridges — Proton Mail Bridge, and Mailpit or similar in
        // testing — serve IMAP over a self-signed certificate on loopback.
        // Certificate validation is waived there and only there: the traffic
        // never leaves the machine, so there is no network path to intercept.
        // For every other host, the system's normal validation applies.
        if Self.isLoopback(host) {
            sec_protocol_options_set_verify_block(
                tls.securityProtocolOptions,
                { _, _, complete in complete(true) },
                queue)
            Log.write("[net] \(host) is loopback — accepting its self-signed certificate")
        }

        let parameters = NWParameters(tls: tls, tcp: tcp)

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw IMAPError.connectionFailed("invalid port \(port)")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        self.connection = connection

        let ready = DispatchSemaphore(value: 0)
        let state = StateBox()
        connection.stateUpdateHandler = { newState in
            switch newState {
            case .ready:
                state.set(nil)
                ready.signal()
            case .failed(let error), .waiting(let error):
                state.set(error)
                ready.signal()
            case .cancelled:
                state.set(NWError.posix(.ECANCELED))
                ready.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)

        if ready.wait(timeout: .now() + timeout) == .timedOut {
            throw IMAPError.connectionFailed("no response from \(host)")
        }
        if let error = state.get() {
            throw IMAPError.connectionFailed("\(host): \(error.localizedDescription)")
        }

        receiveLoop()
        // Server greeting.
        _ = try readLine(timeout: timeout)
        capabilities = (try? fetchCapabilities()) ?? []
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        condition.lock()
        streamClosed = true
        condition.broadcast()
        condition.unlock()
    }

    func logout() {
        _ = try? sendCommand("LOGOUT", timeout: 5)
        disconnect()
    }

    /// Keeps a receive pending at all times, appending into a shared buffer.
    private func receiveLoop() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.condition.lock()
            if let data, !data.isEmpty { self.buffer.append(data) }
            if let error { self.streamError = error }
            if isComplete { self.streamClosed = true }
            self.condition.broadcast()
            self.condition.unlock()

            if error == nil && !isComplete { self.receiveLoop() }
        }
    }

    // MARK: - Reading

    private func readLine(timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }

        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex...newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                var line = String(decoding: lineData, as: UTF8.self)
                if line.hasSuffix("\n") { line.removeLast() }
                if line.hasSuffix("\r") { line.removeLast() }
                return line
            }
            if let error = streamError { throw IMAPError.connectionFailed(error.localizedDescription) }
            if streamClosed { throw IMAPError.connectionFailed("connection closed") }
            if !condition.wait(until: deadline) { throw IMAPError.timedOut }
        }
    }

    private func readBytes(_ count: Int, timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }

        while buffer.count < count {
            if let error = streamError { throw IMAPError.connectionFailed(error.localizedDescription) }
            if streamClosed { throw IMAPError.connectionFailed("connection closed") }
            if !condition.wait(until: deadline) { throw IMAPError.timedOut }
        }
        let slice = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(slice)
    }

    // MARK: - Writing

    private func write(_ text: String) throws {
        guard let connection else { throw IMAPError.connectionFailed("not connected") }
        let semaphore = DispatchSemaphore(value: 0)
        let box = StateBox()
        connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
            box.set(error)
            semaphore.signal()
        })
        if semaphore.wait(timeout: .now() + 20) == .timedOut { throw IMAPError.timedOut }
        if let error = box.get() { throw IMAPError.connectionFailed(error.localizedDescription) }
    }

    private func nextTag() -> String {
        tagCounter += 1
        return String(format: "a%03d", tagCounter)
    }

    /// Sends a command and collects the response.
    ///
    /// Literals (`{1234}` at the end of a line) are read as an exact byte count
    /// rather than as text, which is how message bodies come back.
    @discardableResult
    private func sendCommand(_ command: String, timeout: TimeInterval = 30) throws
        -> (lines: [String], literals: [Data]) {
        let tag = nextTag()
        try write("\(tag) \(command)\r\n")

        var lines: [String] = []
        var literals: [Data] = []

        while true {
            let line = try readLine(timeout: timeout)

            if let braceRange = line.range(of: #"\{(\d+)\}$"#, options: .regularExpression) {
                let digits = line[braceRange].dropFirst().dropLast()
                if let size = Int(digits) {
                    literals.append(try readBytes(size, timeout: timeout))
                    lines.append(line)
                    continue
                }
            }
            lines.append(line)

            if line.hasPrefix(tag + " ") {
                if line.uppercased().contains(" OK") { return (lines, literals) }
                throw IMAPError.protocolError(
                    line.replacingOccurrences(of: tag + " ", with: ""))
            }
        }
    }

    // MARK: - Commands

    @discardableResult
    func fetchCapabilities() throws -> Set<String> {
        let response = try sendCommand("CAPABILITY")
        var found: Set<String> = []
        // Only the untagged "* CAPABILITY ..." line is authoritative. The
        // tagged completion line also contains the word CAPABILITY, and
        // folding it in would import "OK"/"COMPLETED." as fake capabilities.
        for line in response.lines {
            let upper = line.uppercased()
            guard upper.hasPrefix("* CAPABILITY") else { continue }
            for token in upper.split(separator: " ").dropFirst(2) {
                found.insert(String(token))
            }
        }
        capabilities.formUnion(found)
        return found
    }

    var supportsIDLE: Bool { capabilities.contains("IDLE") }

    func login(user: String, password: String) throws {
        func quote(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        // Microsoft advertises LOGINDISABLED and refuses password IMAP outright;
        // saying so is far more useful than a generic rejection.
        if capabilities.contains("LOGINDISABLED") {
            throw IMAPError.authenticationFailed(
                "This server refuses password sign-in (LOGINDISABLED). "
                + "Microsoft accounts must use the browser sign-in option instead.")
        }
        do {
            _ = try sendCommand("LOGIN \(quote(user)) \(quote(password))")
        } catch {
            throw IMAPError.authenticationFailed(friendlyAuthError(error))
        }
        capabilities = (try? fetchCapabilities()) ?? capabilities
    }

    func authenticateXOAUTH2(user: String, token: String) throws {
        let payload = "user=\(user)\u{01}auth=Bearer \(token)\u{01}\u{01}"
        let encoded = Data(payload.utf8).base64EncodedString()
        do {
            _ = try sendCommand("AUTHENTICATE XOAUTH2 \(encoded)")
        } catch {
            // A failed XOAUTH2 leaves the server awaiting a continuation.
            _ = try? write("\r\n")
            throw IMAPError.authenticationFailed(friendlyAuthError(error))
        }
        capabilities = (try? fetchCapabilities()) ?? capabilities
    }

    private func friendlyAuthError(_ error: Error) -> String {
        let detail = error.localizedDescription
        if detail.uppercased().contains("AUTHENTICATIONFAILED")
            || detail.lowercased().contains("invalid credentials")
            || detail.lowercased().contains("username and password not accepted") {
            return "Credentials rejected — Gmail and iCloud need an app password, not your normal one"
        }
        return detail
    }

    func select(_ folder: String, readOnly: Bool = true) throws {
        let command = readOnly ? "EXAMINE" : "SELECT"
        _ = try sendCommand("\(command) \"\(folder)\"")
    }

    /// Highest UID currently in the mailbox, or 0 when empty.
    func highestUID() throws -> Int {
        let response = try sendCommand("UID SEARCH ALL")
        return uids(in: response.lines).max() ?? 0
    }

    func uids(after uid: Int) throws -> [Int] {
        let response = try sendCommand("UID SEARCH UID \(uid + 1):*")
        return uids(in: response.lines).filter { $0 > uid }.sorted()
    }

    private func uids(in lines: [String]) -> [Int] {
        for line in lines where line.uppercased().hasPrefix("* SEARCH") {
            return line.split(separator: " ").compactMap { Int($0) }
        }
        return []
    }

    /// Fetches a message without marking it read. Partial fetch keeps a 10 MB
    /// attachment from being pulled down for a six-digit code.
    func fetchMessage(uid: Int, maxBytes: Int = 262_144) throws -> Data? {
        let response = try sendCommand("UID FETCH \(uid) (BODY.PEEK[]<0.\(maxBytes)>)")
        return response.literals.first
    }

    /// Blocks until the server reports new mail, the deadline passes, or
    /// `shouldStop` goes true. Returns true when something arrived.
    func idle(rearmAfter: TimeInterval, shouldStop: () -> Bool) throws -> Bool {
        let tag = nextTag()
        try write("\(tag) IDLE\r\n")
        _ = try readLine(timeout: 20)          // "+ idling"

        let deadline = Date().addingTimeInterval(rearmAfter)
        var sawActivity = false

        while Date() < deadline && !shouldStop() {
            do {
                let line = try readLine(timeout: 5)
                let upper = line.uppercased()
                if upper.contains("EXISTS") || upper.contains("RECENT") {
                    sawActivity = true
                    break
                }
            } catch IMAPError.timedOut {
                continue
            }
        }

        try write("DONE\r\n")
        for _ in 0..<30 {
            let line = try readLine(timeout: 20)
            if line.hasPrefix(tag + " ") { break }
            if line.uppercased().contains("EXISTS") { sawActivity = true }
        }
        return sawActivity
    }
}

/// Small lock-protected box for handing a value out of a network callback.
private final class StateBox {
    private let lock = NSLock()
    private var value: Error?

    func set(_ newValue: Error?) {
        lock.lock(); value = newValue; lock.unlock()
    }

    func get() -> Error? {
        lock.lock(); defer { lock.unlock() }; return value
    }
}
