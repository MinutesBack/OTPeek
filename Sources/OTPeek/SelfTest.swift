import Foundation

/// Corpus test for the extractor.
///
/// Two things matter and they pull against each other: catching the real code
/// (recall) and never firing on an order number (precision). Every case is
/// modelled on mail and SMS that actually shows up in a normal inbox.
///
/// Run with `./run-tests.sh` or `OTPeek --self-test`.
enum SelfTest {

    private struct Case {
        let name: String
        let subject: String
        let body: String
        let isHTML: Bool
        let sender: String
        let expectKind: HitKind
        let expectValue: String?
    }

    private static let cases: [Case] = [
        // ---------- SMS codes ----------
        .init(name: "google sms", subject: "",
              body: "G-483920 is your Google verification code.",
              isHTML: false, sender: "Google", expectKind: .code, expectValue: "G-483920"),
        .init(name: "stripe sms", subject: "",
              body: "Your Stripe verification code is 728193. Don't share it.",
              isHTML: false, sender: "Stripe", expectKind: .code, expectValue: "728193"),
        .init(name: "apple sms", subject: "",
              body: "Your Apple Account code is: 019283. Do not share it with anyone.",
              isHTML: false, sender: "Apple", expectKind: .code, expectValue: "019283"),
        .init(name: "whatsapp sms", subject: "",
              body: "Your WhatsApp code: 471-829. Don't share this code.",
              isHTML: false, sender: "WhatsApp", expectKind: .code, expectValue: "471829"),
        .init(name: "amazon sms", subject: "",
              body: "482913 is your Amazon OTP. Do not share it with anyone.",
              isHTML: false, sender: "Amazon", expectKind: .code, expectValue: "482913"),
        .init(name: "uber sms", subject: "",
              body: "Your Uber code is 4829. Reply STOP to unsubscribe.",
              isHTML: false, sender: "Uber", expectKind: .code, expectValue: "4829"),
        .init(name: "french bank 3ds", subject: "",
              body: "Code de securite : 903214 pour valider votre achat de 149,90 EUR chez FNAC.",
              isHTML: false, sender: "CIC", expectKind: .code, expectValue: "903214"),
        .init(name: "french activation", subject: "",
              body: "Votre code d'activation Doctolib est 55712. Valable 10 minutes.",
              isHTML: false, sender: "Doctolib", expectKind: .code, expectValue: "55712"),
        .init(name: "code ends sentence", subject: "",
              body: "Votre code de connexion est 284917.",
              isHTML: false, sender: "Qonto", expectKind: .code, expectValue: "284917"),
        .init(name: "8 digit code", subject: "",
              body: "Your security code is 48291736 and expires in 5 minutes.",
              isHTML: false, sender: "Bank", expectKind: .code, expectValue: "48291736"),

        // ---------- Email codes ----------
        .init(name: "subject carries code", subject: "294817 is your Slack code",
              body: "Enter it to sign in.",
              isHTML: false, sender: "Slack", expectKind: .code, expectValue: "294817"),
        .init(name: "github code", subject: "[GitHub] Please verify your device",
              body: "Verification code: 583920\n\nIf you didn't request this, ignore it.",
              isHTML: false, sender: "GitHub", expectKind: .code, expectValue: "583920"),
        .init(name: "html standalone code", subject: "Verify your email",
              body: "<html><body><p>Hi there,</p><table><tr><td style='font-size:32px'>582014</td>"
                  + "</tr></table><p>Enter this verification code to continue.</p>"
                  + "<a href='https://x.com/unsubscribe'>Unsubscribe</a></body></html>",
              isHTML: true, sender: "Notion", expectKind: .code, expectValue: "582014"),
        .init(name: "netflix code", subject: "Your Netflix temporary access code",
              body: "<html><body><p>Temporary access code</p><h1>4829</h1>"
                  + "<p>This code expires in 15 minutes.</p></body></html>",
              isHTML: true, sender: "Netflix", expectKind: .code, expectValue: "4829"),
        .init(name: "code plus order number", subject: "Your verification code",
              body: "Order #48192033 shipped yesterday. Separately: your verification code is 771204.",
              isHTML: false, sender: "Shop", expectKind: .code, expectValue: "771204"),

        // ---------- Links ----------
        .init(name: "magic link", subject: "Sign in to Linear",
              body: "<html><body><p>Click below to sign in.</p>"
                  + "<a href='https://linear.app/auth/magic?token=abc123def456ghi789jkl012'>"
                  + "Sign in to Linear</a>"
                  + "<a href='https://linear.app/unsubscribe'>Unsubscribe</a></body></html>",
              isHTML: true, sender: "Linear", expectKind: .link, expectValue: "linear.app/auth/magic"),
        .init(name: "activation link fr", subject: "Activez votre compte",
              body: "<html><body><a href='https://app.qonto.com/activer/"
                  + "eyJhbGciOiJIUzI1NiJ9xxxxxxxxxxxxxxxxxxxxxxxxx'>Activer mon compte</a></body></html>",
              isHTML: true, sender: "Qonto", expectKind: .link, expectValue: "qonto.com/activer"),
        .init(name: "password reset", subject: "Reset your password",
              body: "<html><body><p>We got a request to reset your password.</p>"
                  + "<a href='https://app.figma.com/reset-password?token=q8fh3f9834hf9834hf'>"
                  + "Reset password</a></body></html>",
              isHTML: true, sender: "Figma", expectKind: .link, expectValue: "reset-password"),
        .init(name: "invite link", subject: "You're invited to the workspace",
              body: "<html><body><a href='https://app.slack.com/invite/accept/"
                  + "T01ABCD-E0192837465-abcdefghij'>Accept invitation</a></body></html>",
              isHTML: true, sender: "Slack", expectKind: .link, expectValue: "invite/accept"),
        .init(name: "prefers code over link", subject: "Confirm your email",
              body: "<html><body><p>Your confirmation code is 918273.</p>"
                  + "<a href='https://app.example.com/verify?token=abcdefghijklmnop'>"
                  + "Verify email</a></body></html>",
              isHTML: true, sender: "Example", expectKind: .code, expectValue: "918273"),

        // ---------- Must NOT fire ----------
        .init(name: "order confirmation", subject: "Your order #48192033 has shipped",
              body: "Tracking number 9374889676 will update in 24h. Total: 129.99 EUR",
              isHTML: false, sender: "Amazon", expectKind: .none, expectValue: nil),
        .init(name: "newsletter", subject: "The Weekly Digest 2024",
              body: "<html><body><p>10 things we learned in 2024. Read the 5 best posts.</p>"
                  + "<a href='https://news.co/blog/post-12345'>Read more</a></body></html>",
              isHTML: true, sender: "Newsletter", expectKind: .none, expectValue: nil),
        .init(name: "invoice fr", subject: "Votre facture",
              body: "Facture n 20240815 d'un montant de 1250,00 EUR. Reference 88213.",
              isHTML: false, sender: "OVH", expectKind: .none, expectValue: nil),
        .init(name: "meeting invite", subject: "Standup at 10:30",
              body: "Join Zoom Meeting 8472 9183 2211 tomorrow.",
              isHTML: false, sender: "Zoom", expectKind: .none, expectValue: nil),
        .init(name: "marketing about 2fa", subject: "Introducing two-factor authentication",
              body: "<html><body><p>We now support 2FA for all 45000 of our customers. "
                  + "Read the announcement.</p><a href='https://blog.co/posts/2fa-launch'>"
                  + "Read the blog post</a></body></html>",
              isHTML: true, sender: "Product", expectKind: .none, expectValue: nil),
        .init(name: "shipping notice", subject: "Your parcel is on its way",
              body: "Parcel 8829301745 is out for delivery. Track it at colissimo.fr",
              isHTML: false, sender: "Colissimo", expectKind: .none, expectValue: nil),
        .init(name: "receipt with amounts", subject: "Receipt from Anthropic",
              body: "Amount paid 240.00 USD on 2025-08-14. Invoice 4829173. Card ending 4242.",
              isHTML: false, sender: "Stripe", expectKind: .none, expectValue: nil),
        .init(name: "calendar reminder", subject: "Reminder: Q3 review",
              body: "Your meeting starts at 14:30 in room 2048. Dial 0142 55 66 77.",
              isHTML: false, sender: "Calendar", expectKind: .none, expectValue: nil),
        .init(name: "promo discount", subject: "20% off this weekend",
              body: "<html><body><p>Use promo SUMMER at checkout. Offer ends 2025.</p>"
                  + "<a href='https://shop.co/sale'>Shop now</a></body></html>",
              isHTML: true, sender: "Shop", expectKind: .none, expectValue: nil),
    ]

    /// Returns the number of failures.
    @discardableResult
    static func run() -> Int {
        var passed = 0
        var failures: [String] = []

        for testCase in cases {
            let result = Extractor.analyze(subject: testCase.subject, body: testCase.body,
                                           isHTML: testCase.isHTML, sender: testCase.sender)
            let got: String? = result.kind == .code ? result.code
                             : (result.kind == .link ? result.link : nil)

            var ok = result.kind == testCase.expectKind
            if ok, let want = testCase.expectValue {
                ok = testCase.expectKind == .link ? (got?.contains(want) ?? false) : (got == want)
            }

            if ok {
                passed += 1
            } else {
                failures.append("  \(testCase.name): expected \(testCase.expectKind.rawValue)"
                    + "=\(testCase.expectValue ?? "nil"), got \(result.kind.rawValue)=\(got ?? "nil")")
            }

            let status = ok ? "PASS" : "FAIL"
            let name = testCase.name.padding(toLength: 24, withPad: " ", startingAt: 0)
            print("[\(status)] \(name) \(result.kind.rawValue) \(got ?? "")")
        }

        print("\n\(passed) passed, \(failures.count) failed")
        if !failures.isEmpty {
            print("\nFailures:")
            failures.forEach { print($0) }
        }
        return failures.count
    }
}
