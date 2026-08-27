import Foundation

/// Minimal HTML reader: flat text, standalone text nodes, and links.
///
/// Deliberately hand-rolled rather than using NSAttributedString's HTML
/// importer, which pulls in WebKit, insists on the main thread, and is far too
/// slow to run on every incoming message.
enum HTMLText {

    struct Parsed {
        let text: String
        let nodes: [String]
        let links: [(href: String, text: String)]
    }

    private static let blockTags: Set<String> = [
        "p", "div", "br", "tr", "td", "th", "table", "li", "ul", "ol",
        "h1", "h2", "h3", "h4", "h5", "h6", "section", "header", "footer",
        "article", "blockquote",
    ]

    private static let skipTags: Set<String> = ["script", "style", "head"]

    static func parse(_ html: String) -> Parsed {
        var parts: [String] = []
        var nodes: [String] = []
        var links: [(href: String, text: String)] = []

        var skipDepth = 0
        var currentHref: String?
        var anchorText = ""
        var buffer = ""

        func flushText() {
            guard !buffer.isEmpty else { return }
            let decoded = decodeEntities(buffer)
            buffer = ""
            guard skipDepth == 0 else { return }
            parts.append(decoded)
            if !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                nodes.append(decoded)
                if currentHref != nil { anchorText += decoded }
            }
        }

        var index = html.startIndex
        while index < html.endIndex {
            let character = html[index]

            if character == "<" {
                flushText()

                // HTML comments and doctypes carry nothing we want.
                if html[index...].hasPrefix("<!--") {
                    if let end = html.range(of: "-->", range: index..<html.endIndex) {
                        index = end.upperBound
                    } else { break }
                    continue
                }

                // Read to the closing '>', respecting quoted attribute values.
                var cursor = html.index(after: index)
                var tag = ""
                var quote: Character?
                while cursor < html.endIndex {
                    let c = html[cursor]
                    if let q = quote {
                        if c == q { quote = nil }
                    } else if c == "\"" || c == "'" {
                        quote = c
                    } else if c == ">" {
                        break
                    }
                    tag.append(c)
                    cursor = html.index(after: cursor)
                }
                index = cursor < html.endIndex ? html.index(after: cursor) : html.endIndex

                let isClosing = tag.hasPrefix("/")
                let body = isClosing ? String(tag.dropFirst()) : tag
                let name = body.prefix { !$0.isWhitespace && $0 != "/" }.lowercased()

                if skipTags.contains(name) {
                    skipDepth = isClosing ? max(0, skipDepth - 1) : skipDepth + 1
                    continue
                }
                if blockTags.contains(name) { parts.append("\n") }

                if name == "a" {
                    if isClosing {
                        if let href = currentHref {
                            links.append((href: href,
                                          text: anchorText.trimmingCharacters(in: .whitespacesAndNewlines)))
                        }
                        currentHref = nil
                        anchorText = ""
                    } else {
                        currentHref = attribute("href", in: body).map(decodeEntities)
                        anchorText = ""
                    }
                }
                continue
            }

            buffer.append(character)
            index = html.index(after: index)
        }
        flushText()

        var text = parts.joined()
        text = text.replacingOccurrences(of: "[ \\t\\r\\u{000B}\\u{000C}]+", with: " ",
                                         options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n\\s*\\n\\s*", with: "\n",
                                         options: .regularExpression)

        return Parsed(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                      nodes: nodes, links: links)
    }

    /// Bare URLs sitting in a plain-text body.
    static func bareURLs(in text: String) -> [(href: String, text: String)] {
        var found: [(href: String, text: String)] = []
        let pattern = try! NSRegularExpression(pattern: #"https?://[^\s<>"']+"#)
        let full = NSRange(location: 0, length: (text as NSString).length)
        for match in pattern.matches(in: text, range: full) {
            var url = (text as NSString).substring(with: match.range)
            while let last = url.last, ".,);]>".contains(last) { url.removeLast() }
            found.append((href: url, text: ""))
        }
        return found
    }

    // MARK: - Helpers

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let nameRange = tag.range(of: name + "=", options: .caseInsensitive) else {
            return nil
        }
        var cursor = nameRange.upperBound
        guard cursor < tag.endIndex else { return nil }

        let first = tag[cursor]
        if first == "\"" || first == "'" {
            cursor = tag.index(after: cursor)
            guard let end = tag[cursor...].firstIndex(of: first) else { return nil }
            return String(tag[cursor..<end])
        }
        let end = tag[cursor...].firstIndex { $0.isWhitespace } ?? tag.endIndex
        return String(tag[cursor..<end])
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "hellip": "…", "mdash": "—", "ndash": "–",
        "rsquo": "'", "lsquo": "'", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "eacute": "é", "egrave": "è", "agrave": "à", "ccedil": "ç",
        "ecirc": "ê", "ocirc": "ô", "ugrave": "ù", "acirc": "â", "icirc": "î",
    ]

    static func decodeEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var output = ""
        var index = input.startIndex

        while index < input.endIndex {
            guard input[index] == "&",
                  let semi = input[index...].firstIndex(of: ";"),
                  input.distance(from: index, to: semi) <= 10 else {
                output.append(input[index])
                index = input.index(after: index)
                continue
            }

            let entity = String(input[input.index(after: index)..<semi])
            if entity.hasPrefix("#") {
                let digits = String(entity.dropFirst())
                let scalarValue: UInt32?
                if digits.lowercased().hasPrefix("x") {
                    scalarValue = UInt32(digits.dropFirst(), radix: 16)
                } else {
                    scalarValue = UInt32(digits)
                }
                if let value = scalarValue, let scalar = Unicode.Scalar(value) {
                    output.append(Character(scalar))
                    index = input.index(after: semi)
                    continue
                }
            } else if let replacement = namedEntities[entity.lowercased()] {
                output.append(replacement)
                index = input.index(after: semi)
                continue
            }

            output.append(input[index])
            index = input.index(after: index)
        }
        return output
    }
}
