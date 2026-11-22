import CryptoKit
import Foundation

/// The QR code Unified Slicer shows under Accounts > Sign in on phone:
/// `unifiedslicer://signin?v=1&h=<IPv4,...>&p=<port>&i=<offer id>&k=<AES-256 key>` (base64url).
/// The computer serves its sign-ins once at `http://<h>:<p>/signin/<i>`, sealed with AES-GCM under
/// the key, which only travels in the QR code. See docs/HLSD/phone-sign-in.md in the repository.
public struct SignInCode: Equatable, Sendable {
    public let hosts: [String]
    public let port: Int
    public let id: String
    public let key: Data

    public init(hosts: [String], port: Int, id: String, key: Data) {
        self.hosts = hosts
        self.port = port
        self.id = id
        self.key = key
    }

    public static func parse(_ text: String) -> SignInCode? {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "unifiedslicer", c.host == "signin", c.user == nil, c.port == nil else { return nil }
        var q = [String: String]()
        for part in (c.percentEncodedQuery ?? "").split(separator: "&") {
            guard let eq = part.firstIndex(of: "="), eq > part.startIndex else { continue }
            q[String(part[..<eq])] = String(part[part.index(after: eq)...])
        }
        guard q["v"] == "1" else { return nil }
        // A link anyone can open: only addresses on the phone's own network are ever fetched from.
        let hosts = (q["h"] ?? "").split(separator: ",").map(String.init).filter { isIPv4($0) && isLocalNetwork($0) }
        guard let port = q["p"].flatMap({ Int($0) }), (1...65535).contains(port),
              let id = q["i"], isBase64URLId(id),
              let k = q["k"], let key = Data(base64Lenient: k),
              !hosts.isEmpty, key.count == 32 else { return nil }
        return SignInCode(hosts: hosts, port: port, id: id, key: key)
    }

    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in (1...3).contains(p.count) && p.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    static func isBase64URLId(_ s: String) -> Bool {
        (16...64).contains(s.count) && s.unicodeScalars.allSatisfy { u in
            (u >= "A" && u <= "Z") || (u >= "a" && u <= "z") || (u >= "0" && u <= "9") || u == "_" || u == "-"
        }
    }
}

/// Addresses a computer on the same network can have: the private ranges, carrier-grade NAT
/// (100.64/10) and link-local, as the computer's own server accepts.
public func isLocalNetwork(_ ip: String) -> Bool {
    let parts = ip.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
    guard parts.count == 4, parts.allSatisfy({ $0 != nil && (0...255).contains($0!) }) else { return false }
    let b = parts.map { $0! }
    return b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168) ||
        (b[0] == 100 && (64...127).contains(b[1])) || (b[0] == 169 && b[1] == 254)
}

/// What the computer handed over. `accounts` carry new ids; see `mergeAccounts`.
public struct HandedOver: Sendable {
    public let computer: String
    public let accounts: [Account]
}

/// A sign-in hand-off that failed, with a message for the person.
public struct HandoffError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct SignInHandoff: Sendable {
    /// Same network only: an address that doesn't answer fast is the wrong one, so try the next.
    let http: HTTPClient

    public init(http: HTTPClient = URLSessionHTTP(requestTimeout: 6, overallTimeout: 15)) { self.http = http }

    /// A sealed offer is a few kilobytes; anything far bigger isn't one.
    static let maxOffer = 1 << 20
    static let nonceSize = 12
    static let tagSize = 16

    /// Fetches and opens the offer, trying each of the computer's addresses.
    public func fetch(_ code: SignInCode) async throws -> HandedOver {
        for host in code.hosts {
            var request = try HTTPRequest("http://\(host):\(code.port)/signin/\(code.id)", headers: ["User-Agent": userAgent])
            request.maxResponseBytes = Self.maxOffer
            let resp: HTTPResponse
            do {
                resp = try await http.send(request)
            } catch is ResponseTooLarge {
                throw HandoffError("The answer is too large to be a sign-in. Make a new code on the computer.")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
            if resp.status == 404 { throw HandoffError("This code was already used or has expired. Make a new one on the computer.") }
            guard (200..<300).contains(resp.status) else { continue }
            if resp.body.count > Self.maxOffer { throw HandoffError("The answer is too large to be a sign-in. Make a new code on the computer.") }
            return try Self.open(code, sealed: resp.body)
        }
        throw HandoffError("Couldn't reach the computer. Check that the phone is on the same Wi-Fi, and that the computer's firewall allows Unified Slicer.")
    }

    /// Decrypts a served offer and reads its accounts.
    public static func open(_ code: SignInCode, sealed: Data) throws -> HandedOver {
        guard sealed.count >= nonceSize + tagSize else { throw HandoffError("The computer sent an incomplete answer.") }
        let bytes = [UInt8](sealed)
        let plain: Data
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: bytes[0..<nonceSize]),
                ciphertext: bytes[nonceSize..<(bytes.count - tagSize)],
                tag: bytes[(bytes.count - tagSize)...]
            )
            plain = try AES.GCM.open(box, using: SymmetricKey(data: code.key), authenticating: Data("unified-signin-v1:\(code.id)".utf8))
        } catch {
            throw HandoffError("The answer didn't match this code. Make a new code on the computer.")
        }
        return try read(String(decoding: plain, as: UTF8.self))
    }

    /// The payload: `{"v":1,"computer":"…","accounts":[{"service":"bambu",…},…]}`. Unknown services are skipped.
    public static func read(_ json: String) throws -> HandedOver {
        guard let root = JSON.parse(json) else { throw HandoffError("The computer sent something this app can't read.") }
        let accounts: [Account] = (root.arr("accounts") ?? []).compactMap { a in
            let label = a.str("label")
            func newId(_ prefix: String) -> String { prefix + "-" + UUID().uuidString.lowercased() }
            switch a.str("service") {
            case "bambu":
                guard let token = a.str("access_token"), let uid = a.str("user_id") else { return nil }
                return .bambu(BambuAccount(id: newId("bambu"), label: label ?? "Bambu Lab", region: a.str("region") ?? "global",
                                           accessToken: token, refreshToken: a.str("refresh_token") ?? "", uid: uid))
            case "elegoo":
                guard let token = a.str("access_token"), let user = a.str("user_id") else { return nil }
                return .elegoo(ElegooAccount(id: newId("elegoo"), label: label ?? "Elegoo", region: a.str("region") ?? "global",
                                             accessToken: token, refreshToken: a.str("refresh_token") ?? "",
                                             accessExpireMs: a.long("access_expire_ms") ?? 0, userId: user))
            case "creality":
                guard let token = a.str("token"), let user = a.str("user_id"), let duid = a.str("device_uid") else { return nil }
                return .creality(CrealityAccount(id: newId("creality"), label: label ?? "Creality Cloud", region: a.str("region") ?? "global",
                                                 token: token, userId: user, deviceUid: duid))
            case "markforged":
                guard let ak = a.str("access_key"), let sk = a.str("secret_key") else { return nil }
                return .markforged(MarkforgedAccount(id: newId("markforged"), label: label ?? "Markforged Eiger", accessKey: ak, secretKey: sk))
            default:
                return nil
            }
        }
        return HandedOver(computer: root.str("computer") ?? "your computer", accounts: accounts)
    }
}

extension Account {
    /// The same account on another sign-in, so an import replaces it rather than listing it twice.
    public func sameLogin(_ other: Account) -> Bool {
        switch (self, other) {
        case let (.bambu(a), .bambu(b)): return a.uid == b.uid && a.region == b.region
        case let (.elegoo(a), .elegoo(b)): return a.userId == b.userId && a.region == b.region
        case let (.creality(a), .creality(b)): return a.userId == b.userId && a.region == b.region
        case let (.markforged(a), .markforged(b)): return a.accessKey == b.accessKey
        default: return false
        }
    }
}

/// `incoming` with each account that is already saved taking over that saved account's id.
public func mergeAccounts(saved: [Account], incoming: [Account]) -> [Account] {
    incoming.map { a in
        guard let existing = saved.first(where: { $0.sameLogin(a) }) else { return a }
        return a.withId(existing.id)
    }
}
