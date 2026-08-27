import Foundation

/// Tests for the mail parser.
///
/// A broken MIME reader fails silently — the watcher keeps running and simply
/// never sees a code — so the end-to-end case at the bottom matters most:
/// raw bytes off the wire all the way through to an extracted code.
extension SelfTest {

    private static let multipartMessage = """
    From: Stripe <no-reply@stripe.com>
    To: someone@example.com
    Subject: =?UTF-8?B?WW91ciB2ZXJpZmljYXRpb24gY29kZQ==?=
    Content-Type: multipart/alternative; boundary="abc123"
    MIME-Version: 1.0

    --abc123
    Content-Type: text/plain; charset="utf-8"
    Content-Transfer-Encoding: quoted-printable

    Your verification code is 582014. It expires in=2010 minu=
    tes. Caf=C3=A9 =3D test.
    --abc123
    Content-Type: text/html; charset="utf-8"
    Content-Transfer-Encoding: base64

    PGh0bWw+PGJvZHk+PHA+RW50ZXIgdGhpcyB2ZXJpZmljYXRpb24gY29kZSB0byBjb250aW51ZS48
    L3A+PHRhYmxlPjx0cj48dGQ+NTgyMDE0PC90ZD48L3RyPjwvdGFibGU+PC9ib2R5PjwvaHRtbD4=
    --abc123--
    """

    private static let plainMessage = """
    From: =?ISO-8859-1?Q?Cr=E9dit_Mutuel?= <alerte@cmut.fr>
    Subject: =?ISO-8859-1?Q?Votre_code_de_v=E9rification?=
    Content-Type: text/plain; charset="iso-8859-1"

    Votre code de securite est 903214.
    """

    static func runMIME() -> Int {
        var failures: [String] = []

        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            print("[\(condition ? "PASS" : "FAIL")] \(name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(detail)")
            if !condition { failures.append("  \(name): \(detail)") }
        }

        // --- multipart/alternative, base64 + quoted-printable ---
        let part = MIME.parse(Data(multipartMessage.replacingOccurrences(of: "\n", with: "\r\n").utf8))
        check("multipart split", part.children.count == 2, "children=\(part.children.count)")

        let subject = MIME.decodeWords(part.header("Subject") ?? "")
        check("rfc2047 base64", subject == "Your verification code", subject)

        let bodies = MIME.bestBodies(part)
        check("quoted-printable", bodies.plain.contains("582014") && bodies.plain.contains("Café"),
              bodies.plain.trimmingCharacters(in: .whitespacesAndNewlines).prefix(46).description)
        check("qp soft line break", bodies.plain.contains("expires in 10 minutes"),
              "soft break should join the wrapped line")
        check("qp literal equals", bodies.plain.contains("= test"), "=3D should become '='")
        check("base64 html", bodies.html.contains("<td>582014</td>"),
              bodies.html.prefix(40).description)

        // --- charset + Q encoding ---
        let plain = MIME.parse(Data(plainMessage.replacingOccurrences(of: "\n", with: "\r\n").utf8))
        let sender = MIME.decodeWords(plain.header("From") ?? "")
        check("rfc2047 q-encoding", sender.contains("Crédit Mutuel"), sender)
        let latinSubject = MIME.decodeWords(plain.header("Subject") ?? "")
        check("latin-1 subject", latinSubject == "Votre code de vérification", latinSubject)

        // --- end to end: raw bytes through to an extracted code ---
        let endToEnd = Extractor.analyze(subject: subject, body: bodies.html,
                                         isHTML: true, sender: "Stripe")
        check("end-to-end extract", endToEnd.kind == .code && endToEnd.code == "582014",
              "\(endToEnd.kind.rawValue)=\(endToEnd.code ?? "nil")")

        let plainBodies = MIME.bestBodies(plain)
        let frenchHit = Extractor.analyze(subject: latinSubject, body: plainBodies.plain,
                                          isHTML: false, sender: sender)
        check("end-to-end french", frenchHit.kind == .code && frenchHit.code == "903214",
              "\(frenchHit.kind.rawValue)=\(frenchHit.code ?? "nil")")

        print("\n\(9 - failures.count) passed, \(failures.count) failed")
        if !failures.isEmpty {
            print("\nFailures:")
            failures.forEach { print($0) }
        }
        return failures.count
    }
}
