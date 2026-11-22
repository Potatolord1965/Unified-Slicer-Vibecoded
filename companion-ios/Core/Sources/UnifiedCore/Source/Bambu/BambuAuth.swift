import Foundation

/// Bambu Lab account sign-in (the same REST API Bambu Studio and Bambu Handy use).
public struct BambuAuth: Sendable {
    public enum Result: Sendable {
        case signedIn(BambuAccount)
        /// Bambu e-mailed a one-time code; finish with `loginWithCode`.
        case needsEmailCode
        /// The account has two-factor authentication; finish with `loginWithTfa`.
        case needsTfa(tfaKey: String)
    }

    let http: HTTPClient
    public init(_ http: HTTPClient) { self.http = http }

    public func login(email: String, password: String, region: String) async throws -> Result {
        let reply = try await post(region, "/v1/user-service/user/login", .object([
            "account": .string(email), "password": .string(password), "apiError": .string(""),
        ]))
        if let token = reply.str("accessToken") {
            return .signedIn(try await finish(email, token, reply.str("refreshToken"), region))
        }
        switch reply.str("loginType") {
        case "verifyCode":
            try await sendEmailCode(email: email, region: region)
            return .needsEmailCode
        case "tfa":
            guard let key = reply.str("tfaKey") else { throw IOError("Bambu asked for 2FA without a key") }
            return .needsTfa(tfaKey: key)
        default:
            throw AuthError("Bambu did not accept the e-mail or password")
        }
    }

    public func sendEmailCode(email: String, region: String) async throws {
        _ = try await post(region, "/v1/user-service/user/sendemail/code", .object(["email": .string(email), "type": .string("codeLogin")]))
    }

    public func loginWithCode(email: String, code: String, region: String) async throws -> BambuAccount {
        let reply = try await post(region, "/v1/user-service/user/login", .object([
            "account": .string(email), "code": .string(code.trimmingCharacters(in: .whitespacesAndNewlines)),
        ]))
        guard let token = reply.str("accessToken") else { throw AuthError("Bambu did not accept the code") }
        return try await finish(email, token, reply.str("refreshToken"), region)
    }

    public func loginWithTfa(email: String, tfaKey: String, code: String, region: String) async throws -> BambuAccount {
        let site = region == "china" ? "https://bambulab.cn" : "https://bambulab.com"
        let request = try HTTPRequest.json("\(site)/api/sign-in/tfa", .object([
            "tfaKey": .string(tfaKey), "tfaCode": .string(code.trimmingCharacters(in: .whitespacesAndNewlines)),
        ])).with("User-Agent", userAgent)
        let resp = try await http.send(request)
        let token = resp.cookies["token"].flatMap { $0.isEmpty ? nil : $0 } ?? JSON.parse(resp.text).str("accessToken")
        guard let t = token else { throw AuthError("Bambu did not accept the two-factor code") }
        return try await finish(email, t, nil, region)
    }

    public func refresh(_ account: BambuAccount) async throws -> BambuAccount {
        if account.refreshToken.isEmpty { throw AuthError("Bambu sign-in expired") }
        let reply: JSON
        do {
            reply = try await post(account.region, "/v1/user-service/user/refreshtoken", .object(["refreshToken": .string(account.refreshToken)]))
        } catch is HTTPError {
            throw AuthError("Bambu sign-in expired")
        }
        guard let token = reply.str("accessToken") else { throw AuthError("Bambu sign-in expired") }
        var a = account
        a.accessToken = token
        a.refreshToken = reply.str("refreshToken") ?? account.refreshToken
        return a
    }

    private func finish(_ email: String, _ token: String, _ refreshToken: String?, _ region: String) async throws -> BambuAccount {
        let pref = try await http.fetchJSON(
            try HTTPRequest(Self.apiBase(region) + "/v1/design-user-service/my/preference", headers: ["Authorization": "Bearer \(token)"])
        )
        guard let uid = pref.str("uid") else { throw IOError("Bambu returned no user id") }
        return BambuAccount(
            id: "bambu-" + UUID().uuidString.lowercased(), label: email, region: region,
            accessToken: token, refreshToken: refreshToken ?? "", uid: uid
        )
    }

    private func post(_ region: String, _ path: String, _ body: JSON) async throws -> JSON {
        do {
            return try await http.fetchJSON(try .json(Self.apiBase(region) + path, body), authErrors: false)
        } catch let e as HTTPError {
            // Bambu answers a wrong password with 400 and a JSON message.
            let msg = JSON.parse(e.body).str("error")
            if (400..<500).contains(e.code) { throw AuthError(msg ?? "Bambu rejected the sign-in") }
            throw e
        }
    }

    public static func apiBase(_ region: String) -> String { region == "china" ? "https://api.bambulab.cn" : "https://api.bambulab.com" }
    public static func mqttHost(_ region: String) -> String { region == "china" ? "cn.mqtt.bambulab.com" : "us.mqtt.bambulab.com" }
}
