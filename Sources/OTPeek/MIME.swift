import Foundation

/// A parsed RFC 822 / MIME message part.
struct MIMEPart {
    var headers: [(name: String, value: String)] = []
    var contentType: String = "text/plain"
    var charset: String?
    var encoding: String = "7bit"
    var filename: String?
    var body: Data = Data()
    var children: [MIMEPart] = []

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Enough of MIME to read a mail body reliably.
///
/// Covers what real providers actually send: folded headers, RFC 2047 encoded
/// words in subjects, quoted-printable and base64 transfer encodings, declared
/// charsets, and nested multipart/alternative trees.
enum MIME {

    // MARK: - Parsing

    static func parse(_ data: Data) -> MIMEPart {
        let lines = splitLines(data)
        var part = MIMEPart()

        // Headers run until the first blank line, with continuation lines
        // folded onto the header before them.
        var index = 0
        var current: (name: String, value: String)?
        while index < lines.count {
            let line = lines[index]
            index += 1
            if line.isEmpty { break }

            let text = String(decoding: line, as: UTF8.self)
            if let first = text.first, first == " " || first == "\t" {
                current?.value += " " + text.trimmingCharacters(in: .whitespaces)
                continue
            }
            if let done = current { part.headers.append(done) }
            if let colon = text.firstIndex(of: ":") {
                current = (name: String(text[text.startIndex..<colon]),
                           value: String(text[text.index(after: colon)...])
                            .trimmingCharacters(in: .whitespaces))
            } else {
                current = nil
            }
        }
        if let done = current { part.headers.append(done) }

        let bodyLines = index < lines.count ? Array(lines[index...]) : []
        part.body = joinLines(bodyLines)

        if let contentType = part.header("Content-Type") {
            part.contentType = contentType
                .split(separator: ";").first
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "text/plain"
            part.charset = parameter("charset", in: contentType)
            if let boundary = parameter("boundary", in: contentType) {
                part.children = splitMultipart(bodyLines, boundary: boundary)
            }
        }
        part.encoding = (part.header("Content-Transfer-Encoding") ?? "7bit")
            .trimmingCharacters(in: .whitespaces).lowercased()
        if let disposition = part.header("Content-Disposition") {
            part.filename = parameter("filename", in: disposition)
        }
        if part.filename == nil, let contentType = part.header("Content-Type") {
            part.filename = parameter("name", in: contentType)
        }
        return part
    }

    private static func splitMultipart(_ lines: [[UInt8]], boundary: String) -> [MIMEPart] {
        let delimiter = Array("--\(boundary)".utf8)
        let terminator = Array("--\(boundary)--".utf8)

        var parts: [MIMEPart] = []
        var buffer: [[UInt8]] = []
        var started = false

        for line in lines {
            if line == terminator || line.starts(with: terminator) {
                if started, !buffer.isEmpty { parts.append(parse(joinLines(buffer))) }
                break
            }
            if line == delimiter || (line.starts(with: delimiter) && line.count == delimiter.count) {
                if started, !buffer.isEmpty { parts.append(parse(joinLines(buffer))) }
                buffer = []
                started = true
                continue
            }
            if started { buffer.append(line) }
        }
        return parts
    }

    // MARK: - Body extraction

    /// Returns the best plain-text and HTML alternatives in the tree.
    static func bestBodies(_ part: MIMEPart) -> (plain: String, html: String) {
        var plain = ""
        var html = ""

        func walk(_ node: MIMEPart) {
            if !node.children.isEmpty {
                node.children.forEach(walk)
                return
            }
            guard node.filename == nil else { return }   // skip attachments
            guard node.contentType == "text/plain" || node.contentType == "text/html" else { return }

            let decoded = decodeBody(node)
            if node.contentType == "text/plain", plain.isEmpty {
                plain = decoded
            } else if node.contentType == "text/html", html.isEmpty {
                html = decoded
            }
        }
        walk(part)
        return (plain, html)
    }

    static func decodeBody(_ part: MIMEPart) -> String {
        let raw: Data
        switch part.encoding {
        case "base64":
            let cleaned = part.body.filter { $0 != 0x0D && $0 != 0x0A && $0 != 0x20 && $0 != 0x09 }
            raw = Data(base64Encoded: Data(cleaned), options: [.ignoreUnknownCharacters]) ?? part.body
        case "quoted-printable":
            raw = decodeQuotedPrintable(part.body)
        default:
            raw = part.body
        }
        return string(from: raw, charset: part.charset)
    }

    // MARK: - Encodings

    static func decodeQuotedPrintable(_ data: Data) -> Data {
        var output: [UInt8] = []
        let bytes = [UInt8](data)
        var index = 0

        func hexValue(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: return byte - 0x30
            case 0x41...0x46: return byte - 0x41 + 10
            case 0x61...0x66: return byte - 0x61 + 10
            default: return nil
            }
        }

        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x3D {   // '='
                // Soft line break: "=\r\n" or "=\n" joins the wrapped line.
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    index += 2
                    continue
                }
                if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A {
                    index += 3
                    continue
                }
                if index + 2 < bytes.count,
                   let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                    output.append(high << 4 | low)
                    index += 3
                    continue
                }
            }
            output.append(byte)
            index += 1
        }
        return Data(output)
    }

    /// RFC 2047 encoded words, e.g. `=?UTF-8?B?...?=` in a Subject line.
    static func decodeWords(_ input: String) -> String {
        guard input.contains("=?") else { return input }

        let pattern = try! NSRegularExpression(
            pattern: #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#)
        let source = input as NSString
        var output = ""
        var cursor = 0

        for match in pattern.matches(in: input,
                                     range: NSRange(location: 0, length: source.length)) {
            if match.range.location > cursor {
                output += source.substring(with: NSRange(location: cursor,
                                                         length: match.range.location - cursor))
            }
            let charset = source.substring(with: match.range(at: 1))
            let kind = source.substring(with: match.range(at: 2)).uppercased()
            let payload = source.substring(with: match.range(at: 3))

            var decoded: Data?
            if kind == "B" {
                decoded = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters])
            } else {
                // Q encoding is quoted-printable with '_' standing in for space.
                let swapped = payload.replacingOccurrences(of: "_", with: " ")
                decoded = decodeQuotedPrintable(Data(swapped.utf8))
            }
            output += decoded.map { string(from: $0, charset: charset) } ?? payload
            cursor = match.range.location + match.range.length
        }

        if cursor < source.length {
            output += source.substring(from: cursor)
        }
        return output
    }

    // MARK: - Helpers

    static func string(from data: Data, charset: String?) -> String {
        if let charset {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
                if let text = String(data: data, encoding: String.Encoding(rawValue: nsEncoding)) {
                    return text
                }
            }
        }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        return String(decoding: data, as: UTF8.self)
    }

    private static func parameter(_ name: String, in header: String) -> String? {
        for chunk in header.split(separator: ";").dropFirst() {
            let piece = chunk.trimmingCharacters(in: .whitespaces)
            guard let equals = piece.firstIndex(of: "=") else { continue }
            let key = piece[piece.startIndex..<equals].trimmingCharacters(in: .whitespaces)
            guard key.caseInsensitiveCompare(name) == .orderedSame else { continue }
            var value = String(piece[piece.index(after: equals)...])
                .trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") { value.removeFirst() }
            if value.hasSuffix("\"") { value.removeLast() }
            return value
        }
        return nil
    }

    private static func splitLines(_ data: Data) -> [[UInt8]] {
        var lines: [[UInt8]] = []
        var current: [UInt8] = []
        for byte in data {
            if byte == 0x0A {
                if current.last == 0x0D { current.removeLast() }
                lines.append(current)
                current = []
            } else {
                current.append(byte)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    private static func joinLines(_ lines: [[UInt8]]) -> Data {
        var output: [UInt8] = []
        for (index, line) in lines.enumerated() {
            if index > 0 { output.append(0x0A) }
            output.append(contentsOf: line)
        }
        return Data(output)
    }
}
