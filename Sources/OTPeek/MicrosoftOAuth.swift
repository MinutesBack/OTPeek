import Foundation

/// OAuth for Outlook and Microsoft 365, using the device code flow.
///
/// Microsoft disabled password-based IMAP, so these accounts must sign in
/// through a browser. Device code is used rather than a redirect flow because
/// it needs no redirect URI registered and no embedded web view: the app shows
/// a short code, the user approves it in their browser, and the refresh token
/// is kept in the Keychain from then on.
///
/// Implemented directly against the endpoints so the app keeps zero dependencies.
enum MicrosoftOAuth {

    static let scope = "https://outlook.office.com/IMAP.AccessAsUser.All offline_access"

    struct DeviceCodeChallenge {
        let userCode: String
        let deviceCode: String
        let verificationURI: String
        let interval: Int
        let expiresIn: Int
    }

    enum OAuthError: LocalizedError {
        case badResponse(String)
        case declined(String)
        case pending

        var errorDescription: String? {
            switch self {
            case .badResponse(let detail): return detail
            case .declined(let detail): return detail
            case .pending: return "waiting for approval"
            }
        }
    }

    // MARK: - Token cache

    private static let cacheLock = NSLock()
    private static var accessTokens: [String: (token: String, expires: Date)] = [:]

    /// A valid access token, refreshed silently when needed.
    static func accessToken(for account: Account) -> String? {
        cacheLock.lock()
        if let cached = accessTokens[account.id], cached.expires > Date().addingTimeInterval(60) {
            cacheLock.unlock()
            return cached.token
        }
        cacheLock.unlock()

        guard let clientID = account.clientID,
              let refreshToken = Keychain.get(refreshKey(account.id)) else { return nil }

        do {
            let tokens = try requestToken(clientID: clientID,
                                          tenant: account.tenant ?? "common",
                                          parameters: [
                                            "grant_type": "refresh_token",
                                            "refresh_token": refreshToken,
                                            "scope": scope,
                                          ])
            store(tokens, for: account.id)
            return tokens.accessToken
        } catch {
            Log.write("[error] \(account.label): token refresh failed — \(error.localizedDescription)")
            return nil
        }
    }

    static func refreshKey(_ accountID: String) -> String { accountID + ".refresh" }

    private static func store(_ tokens: Tokens, for accountID: String) {
        cacheLock.lock()
        accessTokens[accountID] = (tokens.accessToken,
                                   Date().addingTimeInterval(Double(tokens.expiresIn)))
        cacheLock.unlock()
        if let refresh = tokens.refreshToken {
            _ = Keychain.set(refresh, for: refreshKey(accountID))
        }
    }

    // MARK: - Device code flow

    static func beginDeviceFlow(clientID: String, tenant: String) throws -> DeviceCodeChallenge {
        let url = URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/devicecode")!
        let json = try post(url, form: ["client_id": clientID, "scope": scope])

        guard let userCode = json["user_code"] as? String,
              let deviceCode = json["device_code"] as? String,
              let verification = json["verification_uri"] as? String else {
            throw OAuthError.badResponse(
                (json["error_description"] as? String) ?? "unexpected response from Microsoft")
        }
        return DeviceCodeChallenge(userCode: userCode, deviceCode: deviceCode,
                                   verificationURI: verification,
                                   interval: (json["interval"] as? Int) ?? 5,
                                   expiresIn: (json["expires_in"] as? Int) ?? 900)
    }

    /// Polls until the user approves in their browser. Blocking — call off the
    /// main thread. Returns the access token on success.
    static func completeDeviceFlow(challenge: DeviceCodeChallenge, clientID: String,
                                   tenant: String, accountID: String,
                                   shouldCancel: () -> Bool) throws -> String {
        let deadline = Date().addingTimeInterval(Double(challenge.expiresIn))
        var interval = Double(challenge.interval)

        while Date() < deadline {
            if shouldCancel() { throw OAuthError.declined("cancelled") }
            Thread.sleep(forTimeInterval: interval)

            do {
                let tokens = try requestToken(clientID: clientID, tenant: tenant, parameters: [
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "device_code": challenge.deviceCode,
                ])
                store(tokens, for: accountID)
                return tokens.accessToken
            } catch OAuthError.pending {
                continue
            } catch let error as OAuthError {
                if case .badResponse(let detail) = error, detail == "slow_down" {
                    interval += 5
                    continue
                }
                throw error
            }
        }
        throw OAuthError.declined("sign-in timed out")
    }

    // MARK: - HTTP

    private struct Tokens {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
    }

    private static func requestToken(clientID: String, tenant: String,
                                     parameters: [String: String]) throws -> Tokens {
        let url = URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token")!
        var form = parameters
        form["client_id"] = clientID
        let json = try post(url, form: form)

        if let error = json["error"] as? String {
            if error == "authorization_pending" { throw OAuthError.pending }
            if error == "slow_down" { throw OAuthError.badResponse("slow_down") }
            throw OAuthError.declined((json["error_description"] as? String) ?? error)
        }
        guard let accessToken = json["access_token"] as? String else {
            throw OAuthError.badResponse("no access token in response")
        }
        return Tokens(accessToken: accessToken,
                      refreshToken: json["refresh_token"] as? String,
                      expiresIn: (json["expires_in"] as? Int) ?? 3600)
    }

    private static func post(_ url: URL, form: [String: String]) throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form
            .map { "\($0.key)=\(percentEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
        request.timeoutInterval = 30

        let semaphore = DispatchSemaphore(value: 0)
        var payload: Data?
        var failure: Error?

        URLSession.shared.dataTask(with: request) { data, _, error in
            payload = data
            failure = error
            semaphore.signal()
        }.resume()

        if semaphore.wait(timeout: .now() + 35) == .timedOut {
            throw OAuthError.badResponse("Microsoft did not respond")
        }
        if let failure { throw OAuthError.badResponse(failure.localizedDescription) }
        guard let payload,
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw OAuthError.badResponse("could not read Microsoft's response")
        }
        return json
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
