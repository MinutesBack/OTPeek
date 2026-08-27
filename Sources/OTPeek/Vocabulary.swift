import Foundation

/// Words and URL shapes the extractor scores against.
///
/// English and French are both first-class. The rest are a cheap safety net
/// for the occasional foreign-language sender.
enum Vocabulary {

    /// Phrases that, near a candidate, make it very likely to be a real code.
    static let codeKeywords: [String] = [
        // english
        "verification code", "verification", "verify", "one-time code", "one time code",
        "one-time password", "single-use code", "otp", "passcode", "pass code",
        "security code", "access code", "confirmation code", "confirm your",
        "authentication code", "auth code", "login code", "log-in code", "sign-in code",
        "sign in code", "temporary code", "your code", "code is", "enter the code",
        "enter this code", "pin code", "activation code", "unlock code", "recovery code",
        // french
        "code de verification", "code de vérification", "code de securite",
        "code de sécurité", "code de confirmation", "code d'acces", "code d'accès",
        "code a usage unique", "code à usage unique", "mot de passe a usage unique",
        "mot de passe à usage unique", "code d'activation", "code de connexion",
        "votre code", "code temporaire", "authentification", "verifiez", "vérifiez",
        "confirmez", "saisissez le code", "entrez le code", "code secret",
        // spanish / german / italian / portuguese
        "codigo de verificacion", "código de verificación", "codigo de seguridad",
        "bestatigungscode", "bestätigungscode", "sicherheitscode", "verifizierungscode",
        "codice di verifica", "codice di sicurezza", "codigo de verificacao",
        "código de verificação",
    ]

    /// Weaker signals. "2FA" is here rather than above because an article
    /// discussing two-factor auth is not itself a two-factor code.
    static let weakKeywords: [String] = [
        "code", "pin", "token", "otp", "verifica", "verifiz",
        "2fa", "mfa", "two-factor", "two factor", "authentification",
    ]

    /// Labels that mean a neighbouring number is not a login code. These hug
    /// their number in practice ("Order #48192033"), so proximity matters.
    static let negativeKeywords: [String] = [
        "order", "invoice", "receipt", "tracking", "shipment", "shipping", "delivery",
        "reference number", "ticket number", "case number", "account number",
        "customer number", "member number", "policy number", "transaction",
        "card ending", "ending in", "expires on", "valid until",
        "amount", "total", "price", "balance", "phone", "call us", "tel:", "zip",
        "postal", "suite", "floor",
        "commande", "facture", "recu", "reçu", "suivi", "livraison", "expedition",
        "expédition", "numero de commande", "numéro de commande", "montant",
        "prix", "solde", "telephone", "téléphone", "siret", "tva",
    ]

    /// URL path fragments that look like a genuine "click here to get in" link.
    static let linkPathHints: [String] = [
        "verify", "verification", "verif", "confirm", "confirmation", "activate",
        "activation", "magic", "magiclink", "passwordless", "onetime", "one-time",
        "signin", "sign-in", "login", "log-in", "auth", "authenticate", "authorize",
        "validate", "validation", "invite", "invitation", "accept", "join",
        "reset", "recover", "setpassword", "set-password", "createpassword",
        "emailconfirm", "confirm-email", "verify-email", "activateaccount",
        "valider", "confirmer", "activer", "connexion", "inscription",
    ]

    /// Query parameters that carry the actual secret.
    static let linkQueryHints: [String] = [
        "token", "code", "otp", "key", "confirmation", "verification", "verify",
        "activation", "auth", "nonce", "signature", "invite",
    ]

    /// Anchor text that means "this is the button you want".
    static let linkTextHints: [String] = [
        "verify", "verify email", "verify my", "confirm", "confirm email",
        "confirm my", "activate", "activate account", "sign in", "log in", "login",
        "get started", "accept invite", "accept invitation", "join", "continue",
        "reset password", "set password", "create password", "validate",
        "click here", "confirm your email", "verify your email",
        "verifier", "vérifier", "confirmer", "activer", "se connecter",
        "valider", "reinitialiser", "réinitialiser", "definir", "définir",
        "cliquez ici", "commencer", "rejoindre", "accepter",
    ]

    /// Links that are never what you want, however well they score.
    static let linkBlocklist: [String] = [
        "unsubscribe", "désabonn", "desabonn", "opt-out", "optout", "preferences",
        "privacy", "policy", "terms", "legal", "cookie", "help", "support",
        "contact", "about", "blog", "twitter.com", "facebook.com", "instagram.com",
        "linkedin.com", "youtube.com", "tiktok.com", "apps.apple.com",
        "play.google.com", "manage-preferences", "email-settings",
        "list-manage", "mailto:", "tel:", "webversion", "view-in-browser",
        "viewinbrowser", "voir-en-ligne",
    ]

    /// Tracking pixels dressed up as links.
    static let pixelHints: [String] = ["/open?", "/pixel", "/track/open", ".gif", "spacer", "1x1"]
}
