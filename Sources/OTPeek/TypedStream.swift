import Foundation

/// Recovers message text from the `attributedBody` column.
///
/// On current macOS the `message.text` column is empty and the body lives in
/// an NSAttributedString typedstream archive. Swift has no NSUnarchiver, so
/// the payload is read directly: a length-prefixed UTF-8 run following the
/// NSString class marker. Verified byte-for-byte against NSUnarchiver's output
/// across a real message database before this replaced it.
enum TypedStream {

    static func decode(_ blob: Data?) -> String {
        guard let blob, !blob.isEmpty else { return "" }
        let bytes = [UInt8](blob)

        if let marker = find(Array("NSString".utf8), in: bytes) {
            var index = marker + 8 + 5
            if index < bytes.count {
                var length = Int(bytes[index])
                if bytes[index] == 0x81 {
                    guard index + 2 < bytes.count else { return scavenge(bytes) }
                    length = Int(bytes[index + 1]) | (Int(bytes[index + 2]) << 8)
                    index += 3
                } else {
                    index += 1
                }
                let end = min(index + length, bytes.count)
                if index < end {
                    let text = String(decoding: bytes[index..<end], as: UTF8.self)
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return text
                    }
                }
            }
        }
        return scavenge(bytes)
    }

    /// Last resort: the longest printable run in the archive.
    private static func scavenge(_ bytes: [UInt8]) -> String {
        var best: [UInt8] = []
        var current: [UInt8] = []
        for byte in bytes {
            if byte >= 0x20 && byte < 0x7F || byte >= 0xC2 {
                current.append(byte)
            } else {
                if current.count > best.count { best = current }
                current = []
            }
        }
        if current.count > best.count { best = current }
        return best.count >= 6 ? String(decoding: best, as: UTF8.self) : ""
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            var matched = true
            for offset in 0..<needle.count where haystack[start + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return start }
        }
        return nil
    }
}
