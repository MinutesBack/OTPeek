import Foundation
import SQLite3

enum SourceState: String {
    case ok, connecting, error
}

/// Watches the local Messages database for incoming SMS and iMessage codes.
///
/// Nothing leaves the Mac: chat.db is the same file Messages.app uses and
/// already holds everything an iPhone forwards over. Reading it requires Full
/// Disk Access on the app bundle.
final class MessagesWatcher {

    typealias MessageHandler = (IncomingMessage) -> Void
    typealias StatusHandler = (String, SourceState, String) -> Void

    /// Apple's reference date (2001-01-01) as a Unix timestamp.
    private static let appleEpoch: Double = 978_307_200

    private let onMessage: MessageHandler
    private let onStatus: StatusHandler
    private let maxAgeMinutes: Int
    private let pollInterval: TimeInterval

    private let queue = DispatchQueue(label: "com.otpeek.messages")
    private var timer: DispatchSourceTimer?
    private var db: OpaquePointer?
    private var lastRowID: Int64 = 0

    private var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db")
    }

    init(maxAgeMinutes: Int, pollInterval: TimeInterval = 2.0,
         onMessage: @escaping MessageHandler, onStatus: @escaping StatusHandler) {
        self.maxAgeMinutes = maxAgeMinutes
        self.pollInterval = pollInterval
        self.onMessage = onMessage
        self.onStatus = onStatus
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard FileManager.default.fileExists(atPath: self.databaseURL.path) else {
                self.onStatus("sms", .error, "No Messages data — turn on Text Message Forwarding")
                return
            }
            guard self.open() else {
                self.onStatus("sms", .error, "Full Disk Access needed for SMS")
                return
            }

            self.lastRowID = self.maxRowID()
            self.selfTest()
            self.onStatus("sms", .ok, "Watching Messages")

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.pollInterval, repeating: self.pollInterval)
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            if let db = self?.db { sqlite3_close(db) }
            self?.db = nil
        }
    }

    // MARK: - Database

    private func open() -> Bool {
        var handle: OpaquePointer?
        let uri = "file:\(databaseURL.path)?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return false
        }
        // Opening can succeed while reading is still blocked, so probe.
        var statement: OpaquePointer?
        let probe = sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM message", -1, &statement, nil)
        let ok = probe == SQLITE_OK && sqlite3_step(statement) == SQLITE_ROW
        sqlite3_finalize(statement)
        if !ok {
            sqlite3_close(handle)
            return false
        }
        db = handle
        return true
    }

    private func maxRowID() -> Int64 {
        guard let db else { return 0 }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT MAX(ROWID) FROM message", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    /// Confirms message bodies actually decode on this machine.
    ///
    /// Logs counts only. The failure being ruled out is a decoder that quietly
    /// returns empty text for every row, which would leave the watcher running
    /// but permanently blind.
    private func selfTest() {
        guard let db else { return }
        let sql = """
            SELECT m.text, m.attributedBody FROM message m
            WHERE m.is_from_me = 0 ORDER BY m.ROWID DESC LIMIT 25
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }

        var plain = 0, blob = 0, empty = 0, total = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            total += 1
            let text = columnText(statement, 0)
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                plain += 1
            } else if !TypedStream.decode(columnBlob(statement, 1))
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blob += 1
            } else {
                empty += 1
            }
        }
        Log.write("[ok] sms self-test: \(total) recent, \(plain) plain, "
                  + "\(blob) decoded from blob, \(empty) unreadable")
    }

    private func poll() {
        guard let db else { return }
        let cutoff = Date().addingTimeInterval(-Double(maxAgeMinutes) * 60)

        let sql = """
            SELECT m.ROWID, m.text, m.attributedBody, m.date, m.service, h.id
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE m.ROWID > ? AND m.is_from_me = 0
            ORDER BY m.ROWID ASC LIMIT 50
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(statement, 1, lastRowID)

        while sqlite3_step(statement) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(statement, 0)
            lastRowID = max(lastRowID, rowID)

            var body = columnText(statement, 1) ?? ""
            if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                body = TypedStream.decode(columnBlob(statement, 2))
            }
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            // `date` is nanoseconds since 2001 on anything modern, seconds on
            // very old databases.
            let raw = Double(sqlite3_column_int64(statement, 3))
            let seconds = raw > 1e11 ? raw / 1e9 : raw
            let received = Date(timeIntervalSince1970: seconds + Self.appleEpoch)
            guard received >= cutoff else { continue }

            let service = columnText(statement, 4) ?? "Messages"
            let sender = columnText(statement, 5) ?? "Unknown"

            onMessage(IncomingMessage(
                source: "sms", account: service, accountID: nil,
                sender: sender, subject: "", body: body,
                plainAlternative: nil, isHTML: false, received: received))
        }
    }

    // MARK: - Column helpers

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private func columnBlob(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0 else { return nil }
        return Data(bytes: pointer, count: count)
    }
}
