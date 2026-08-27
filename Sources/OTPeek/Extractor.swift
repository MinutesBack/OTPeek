import Foundation

enum HitKind: String { case code, link, none }

struct ExtractionResult {
    let kind: HitKind
    let code: String?
    let link: String?
    let linkLabel: String?
    let confidence: Double
    let notes: [String]

    static let empty = ExtractionResult(kind: .none, code: nil, link: nil,
                                        linkLabel: nil, confidence: 0, notes: [])
}

private struct Candidate {
    let value: String
    let score: Double
    let reason: String
}

/// Finds one-time codes and verification links.
///
/// Everything is scored rather than first-match. The failure that actually
/// hurts is pasting an order number into a login form, so precision is
/// weighted at least as heavily as recall.
enum Extractor {

    // MARK: - Patterns

    /// Ordered most- to least-specific: (regex, base score, label).
    private static let patterns: [(NSRegularExpression, Double, String)] = {
        func re(_ p: String) -> NSRegularExpression {
            // These are fixed literals; a failure here is a programming error.
            try! NSRegularExpression(pattern: p, options: [])
        }
        return [
            (re(#"\b([A-Z]{1,3}-\d{4,8})\b"#), 5.0, "prefixed"),
            (re(#"\b(\d{3})[ \#u{00A0}\#u{202F}-](\d{3})\b"#), 3.5, "split-6"),
            // Rejects decimals (129.99) and dates (15/08/2024), but still allows
            // a code that ends a sentence ("your code is 728193.").
            (re(#"(?<!\d)(?<![\d][.,/-])(\d{4,8})(?!\d)(?![.,/-]\d)"#), 3.0, "numeric"),
            (re(#"\b(?=[A-Z0-9]{5,10}\b)(?=[A-Z0-9]*\d)(?=[A-Z0-9]*[A-Z])([A-Z0-9]{5,10})\b"#), 2.5, "alnum"),
        ]
    }()

    private static let yearPattern = try! NSRegularExpression(pattern: #"^(19|20)\d{2}$"#)
    private static let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s<>"']+"#)

    // MARK: - Proximity

    /// Distance in characters from the candidate to the closest term.
    ///
    /// Proximity is the whole point: "Order #" sits flush against its number,
    /// while a code mentioned in the same paragraph as an order number is not
    /// an order number. A flat window over the neighbourhood conflates the two.
    private static func nearest(_ hay: NSString, terms: [String],
                                cStart: Int, cEnd: Int,
                                before: Int, after: Int,
                                wordBoundary: Bool = false) -> (Int, String)? {
        let lo = max(0, cStart - before)
        let hi = min(hay.length, cEnd + after)
        guard hi > lo else { return nil }
        let window = NSRange(location: lo, length: hi - lo)

        var best: (Int, String)?
        for term in terms {
            var searchFrom = window.location
            while searchFrom < window.location + window.length {
                let remaining = NSRange(location: searchFrom,
                                        length: window.location + window.length - searchFrom)
                // Case-insensitive search on the original string avoids
                // lowercasing, which can shift UTF-16 offsets.
                let found = hay.range(of: term, options: .caseInsensitive, range: remaining)
                if found.location == NSNotFound { break }
                searchFrom = found.location + 1

                if wordBoundary {
                    let beforeIdx = found.location - 1
                    let afterIdx = found.location + found.length
                    let prev: Character? = beforeIdx >= 0
                        ? Character(hay.substring(with: NSRange(location: beforeIdx, length: 1)))
                        : nil
                    let next: Character? = afterIdx < hay.length
                        ? Character(hay.substring(with: NSRange(location: afterIdx, length: 1)))
                        : nil
                    if let p = prev, p.isLetter || p.isNumber { continue }
                    if let n = next, n.isLetter || n.isNumber { continue }
                }

                let termStart = found.location
                let termEnd = found.location + found.length
                let distance: Int
                if termEnd <= cStart {
                    distance = cStart - termEnd
                } else if termStart >= cEnd {
                    distance = termStart - cEnd
                } else {
                    distance = 0
                }
                if best == nil || distance < best!.0 { best = (distance, term) }
            }
        }
        return best
    }

    private static func keywordBonus(_ hay: NSString, _ cStart: Int, _ cEnd: Int) -> (Double, String) {
        if let (distance, term) = nearest(hay, terms: Vocabulary.codeKeywords,
                                          cStart: cStart, cEnd: cEnd, before: 110, after: 70) {
            return (distance <= 45 ? 6.0 : 4.0, "near '\(term)'")
        }
        if let (distance, term) = nearest(hay, terms: Vocabulary.weakKeywords,
                                          cStart: cStart, cEnd: cEnd, before: 110, after: 70,
                                          wordBoundary: true) {
            return (distance <= 45 ? 2.0 : 1.0, "near '\(term)'")
        }
        return (0, "")
    }

    private static func negativePenalty(_ hay: NSString, _ cStart: Int, _ cEnd: Int) -> (Double, String) {
        guard let (distance, term) = nearest(hay, terms: Vocabulary.negativeKeywords,
                                             cStart: cStart, cEnd: cEnd, before: 34, after: 20)
        else { return (0, "") }
        return (distance <= 14 ? 7.0 : 4.0, "looks like \(term)")
    }

    private static func insideURL(_ hay: NSString, _ range: NSRange) -> Bool {
        let full = NSRange(location: 0, length: hay.length)
        for match in urlPattern.matches(in: hay as String, range: full) {
            if match.range.location <= range.location,
               range.location + range.length <= match.range.location + match.range.length {
                return true
            }
        }
        return false
    }

    // MARK: - Codes

    private static func findCode(subject: String, body: String, nodes: [String]) -> Candidate? {
        let haystack = subject + "\n" + body
        let hay = haystack as NSString
        let full = NSRange(location: 0, length: hay.length)
        let subjectLength = (subject as NSString).length

        let subjectHasKeyword = (Vocabulary.codeKeywords + Vocabulary.weakKeywords).contains {
            subject.range(of: $0, options: .caseInsensitive) != nil
        }

        var best: Candidate?

        for (pattern, base, label) in patterns {
            for match in pattern.matches(in: haystack, range: full) {
                var raw = ""
                for group in 1..<match.numberOfRanges {
                    let r = match.range(at: group)
                    if r.location != NSNotFound { raw += hay.substring(with: r) }
                }
                if raw.isEmpty { continue }

                let value = raw.replacingOccurrences(of: " ", with: "")
                if insideURL(hay, match.range) { continue }

                let isYear = yearPattern.firstMatch(
                    in: value, range: NSRange(location: 0, length: (value as NSString).length)) != nil
                if label == "numeric" && isYear && !subjectHasKeyword { continue }

                // Template filler like 000000 / 111111.
                if value.allSatisfy(\.isNumber), Set(value).count == 1, value.count > 4 { continue }

                var score = base
                let (bonus, why0) = keywordBonus(hay, match.range.location,
                                                 match.range.location + match.range.length)
                score += bonus
                let (penalty, bad) = negativePenalty(hay, match.range.location,
                                                     match.range.location + match.range.length)
                score -= penalty
                var why = why0

                if value.allSatisfy(\.isNumber) {
                    score += [4: 0.5, 5: 0.8, 6: 2.0, 7: 0.8, 8: 1.0][value.count] ?? 0
                    // Round numbers are quantities ("45000 customers"), not codes.
                    if value.count >= 4 && value.hasSuffix("000") { score -= 4.0 }
                }

                if match.range.location < subjectLength {
                    score += 2.5
                    why = (why + " in subject").trimmingCharacters(in: .whitespaces)
                }

                // The strongest signal in HTML mail: a text node that is nothing
                // but the code, alone in its own styled cell.
                for node in nodes {
                    let stripped = node.trimmingCharacters(in: .whitespacesAndNewlines)
                    if stripped == raw.trimmingCharacters(in: .whitespacesAndNewlines) || stripped == value {
                        score += 5.0
                        why = (why + " standalone").trimmingCharacters(in: .whitespaces)
                        break
                    }
                }

                if bonus == 0 && penalty == 0 && label == "numeric" { score -= 2.0 }

                if best == nil || score > best!.score {
                    let reason = !why.isEmpty ? why : (!bad.isEmpty ? bad : label)
                    best = Candidate(value: value, score: score, reason: reason)
                }
            }
        }
        return best
    }

    // MARK: - Links

    private static func findLink(_ links: [(href: String, text: String)]) -> (String, String, Double)? {
        var best: (String, String, Double)?

        for link in links {
            let href = link.href
            let low = href.lowercased()
            guard low.hasPrefix("http://") || low.hasPrefix("https://") else { continue }

            let anchorLow = link.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if Vocabulary.linkBlocklist.contains(where: { low.contains($0) }) { continue }
            if Vocabulary.linkBlocklist.contains(where: { $0.count > 5 && anchorLow.contains($0) }) { continue }
            if anchorLow.isEmpty, Vocabulary.pixelHints.contains(where: { low.contains($0) }) { continue }

            var score = 0.0
            if Vocabulary.linkPathHints.contains(where: { low.contains($0) }) { score += 4.0 }
            if let queryStart = low.firstIndex(of: "?") {
                let query = String(low[low.index(after: queryStart)...])
                if Vocabulary.linkQueryHints.contains(where: { query.contains($0) }) { score += 2.0 }
            }
            if !anchorLow.isEmpty,
               Vocabulary.linkTextHints.contains(where: { anchorLow.contains($0) }) { score += 4.0 }

            // A long opaque path segment usually means an embedded token.
            if href.range(of: #"/[A-Za-z0-9_-]{24,}"#, options: .regularExpression) != nil { score += 2.0 }
            if href.count > 400 { score -= 1.0 }

            guard score > 0 else { continue }
            if best == nil || score > best!.2 {
                let label = link.text.trimmingCharacters(in: .whitespacesAndNewlines)
                best = (href, label.isEmpty ? "Open link" : label, score)
            }
        }
        return best
    }

    // MARK: - Entry point

    static func analyze(subject: String, body: String,
                        isHTML: Bool, sender: String = "") -> ExtractionResult {
        let text: String
        let nodes: [String]
        let links: [(href: String, text: String)]

        if isHTML {
            let parsed = HTMLText.parse(body)
            text = parsed.text
            nodes = parsed.nodes
            links = parsed.links
        } else {
            text = body
            nodes = body.split(separator: "\n").map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            links = HTMLText.bareURLs(in: body)
        }

        let code = findCode(subject: subject, body: text, nodes: nodes)
        let link = findLink(links)

        let contextPrefix = String(text.prefix(400))
        let context = "\(sender) \(subject) \(contextPrefix)"
        let contextIsAuth = Vocabulary.codeKeywords.contains {
            context.range(of: $0, options: .caseInsensitive) != nil
        } || Vocabulary.weakKeywords.contains {
            context.range(of: "\\b" + NSRegularExpression.escapedPattern(for: $0),
                          options: [.regularExpression, .caseInsensitive]) != nil
        }

        // A code you can paste beats a link you have to click, so it wins ties.
        if let code, code.score >= 7.0 {
            return ExtractionResult(kind: .code, code: code.value, link: link?.0,
                                    linkLabel: link?.1,
                                    confidence: min(1.0, code.score / 14.0),
                                    notes: [code.reason])
        }

        if let link, link.2 >= 6.0 || (link.2 >= 4.0 && contextIsAuth) {
            let pairedCode = (code != nil && code!.score >= 5.0) ? code!.value : nil
            return ExtractionResult(kind: .link, code: pairedCode, link: link.0,
                                    linkLabel: link.1,
                                    confidence: min(1.0, link.2 / 10.0),
                                    notes: ["link score \(Int(link.2))"])
        }

        if let code, code.score >= 5.5, contextIsAuth {
            return ExtractionResult(kind: .code, code: code.value, link: nil, linkLabel: nil,
                                    confidence: min(1.0, code.score / 14.0),
                                    notes: [code.reason])
        }

        return .empty
    }
}
