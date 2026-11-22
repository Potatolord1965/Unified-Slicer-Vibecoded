import Foundation

/// Printer brand. `accent` matches the desktop app's per-brand accent (AccentColor.hpp), as RGB.
public enum Brand: String, Codable, CaseIterable, Sendable {
    case bambu, elegoo, creality, markforged, prusa, klipper, octoprint, other

    public var label: String {
        switch self {
        case .bambu: return "Bambu Lab"
        case .elegoo: return "Elegoo"
        case .creality: return "Creality"
        case .markforged: return "Markforged"
        case .prusa: return "Prusa"
        case .klipper: return "Klipper"
        case .octoprint: return "OctoPrint"
        case .other: return "Printer"
        }
    }

    public var accent: UInt32 {
        switch self {
        case .bambu: return 0x2FA84F
        case .elegoo: return 0x3A6FD8
        case .creality: return 0xD8762C
        case .markforged: return 0x8B8F95
        case .prusa: return 0xFA6831
        case .klipper: return 0xB12F36
        case .octoprint: return 0x13C100
        case .other: return 0x767676
        }
    }
}

/// Printers added by address on the local network.
public enum LanKind: String, Codable, CaseIterable, Sendable {
    case bambu = "BAMBU"
    case elegooCC2 = "ELEGOO_CC2"
    case moonraker = "MOONRAKER"
    case octoprint = "OCTOPRINT"
    case prusaLink = "PRUSALINK"

    public var label: String {
        switch self {
        case .bambu: return "Bambu Lab (LAN mode)"
        case .elegooCC2: return "Elegoo Centauri Carbon 2"
        case .moonraker: return "Klipper / Moonraker"
        case .octoprint: return "OctoPrint"
        case .prusaLink: return "PrusaLink"
        }
    }

    public var brand: Brand {
        switch self {
        case .bambu: return .bambu
        case .elegooCC2: return .elegoo
        case .moonraker: return .klipper
        case .octoprint: return .octoprint
        case .prusaLink: return .prusa
        }
    }

    public var secretLabel: String? {
        switch self {
        case .bambu, .elegooCC2: return "Access code"
        case .moonraker: return "API key (optional)"
        case .octoprint, .prusaLink: return "API key"
        }
    }

    public var needsSerial: Bool { self == .bambu }
}

public struct BambuAccount: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var region: String
    public var accessToken: String
    public var refreshToken: String
    public var uid: String

    public init(id: String, label: String, region: String = "global", accessToken: String, refreshToken: String = "", uid: String) {
        self.id = id
        self.label = label
        self.region = region
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.uid = uid
    }
}

public struct ElegooAccount: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var region: String
    public var accessToken: String
    public var refreshToken: String
    public var accessExpireMs: Int64
    public var userId: String

    public init(id: String, label: String, region: String = "global", accessToken: String, refreshToken: String = "", accessExpireMs: Int64 = 0, userId: String) {
        self.id = id
        self.label = label
        self.region = region
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessExpireMs = accessExpireMs
        self.userId = userId
    }
}

public struct CrealityAccount: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var region: String
    public var token: String
    public var userId: String
    public var deviceUid: String

    public init(id: String, label: String, region: String = "global", token: String, userId: String, deviceUid: String) {
        self.id = id
        self.label = label
        self.region = region
        self.token = token
        self.userId = userId
        self.deviceUid = deviceUid
    }
}

public struct MarkforgedAccount: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var accessKey: String
    public var secretKey: String

    public init(id: String, label: String, accessKey: String, secretKey: String) {
        self.id = id
        self.label = label
        self.accessKey = accessKey
        self.secretKey = secretKey
    }
}

public struct LanPrinter: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var kind: LanKind
    /// IP address, host name or base URL.
    public var host: String
    public var secret: String
    public var serial: String

    public init(id: String, label: String, kind: LanKind, host: String, secret: String = "", serial: String = "") {
        self.id = id
        self.label = label
        self.kind = kind
        self.host = host
        self.secret = secret
        self.serial = serial
    }
}

/// A signed-in cloud account or a directly reachable printer. Saved (in the keychain) by the app.
public enum Account: Codable, Equatable, Sendable, Identifiable {
    case bambu(BambuAccount)
    case elegoo(ElegooAccount)
    case creality(CrealityAccount)
    case markforged(MarkforgedAccount)
    case lan(LanPrinter)

    public var id: String {
        switch self {
        case .bambu(let a): return a.id
        case .elegoo(let a): return a.id
        case .creality(let a): return a.id
        case .markforged(let a): return a.id
        case .lan(let a): return a.id
        }
    }

    public var label: String {
        switch self {
        case .bambu(let a): return a.label
        case .elegoo(let a): return a.label
        case .creality(let a): return a.label
        case .markforged(let a): return a.label
        case .lan(let a): return a.label
        }
    }

    public var brand: Brand {
        switch self {
        case .bambu: return .bambu
        case .elegoo: return .elegoo
        case .creality: return .creality
        case .markforged: return .markforged
        case .lan(let p): return p.kind.brand
        }
    }

    public var kindLabel: String {
        switch self {
        case .bambu: return "Bambu Cloud"
        case .elegoo: return "Elegoo Cloud"
        case .creality: return "Creality Cloud"
        case .markforged: return "Markforged Eiger"
        case .lan(let p): return "LAN · \(p.kind.label)"
        }
    }

    public var lan: LanPrinter? {
        if case .lan(let p) = self { return p }
        return nil
    }

    /// The same account under another id.
    public func withId(_ id: String) -> Account {
        switch self {
        case .bambu(var a): a.id = id; return .bambu(a)
        case .elegoo(var a): a.id = id; return .elegoo(a)
        case .creality(var a): a.id = id; return .creality(a)
        case .markforged(var a): a.id = id; return .markforged(a)
        case .lan(var a): a.id = id; return .lan(a)
        }
    }

    private enum CodingKeys: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let type = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .type)
        switch type {
        case "bambu": self = .bambu(try BambuAccount(from: decoder))
        case "elegoo": self = .elegoo(try ElegooAccount(from: decoder))
        case "creality": self = .creality(try CrealityAccount(from: decoder))
        case "markforged": self = .markforged(try MarkforgedAccount(from: decoder))
        case "lan": self = .lan(try LanPrinter(from: decoder))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown account type \(type)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bambu(let a): try c.encode("bambu", forKey: .type); try a.encode(to: encoder)
        case .elegoo(let a): try c.encode("elegoo", forKey: .type); try a.encode(to: encoder)
        case .creality(let a): try c.encode("creality", forKey: .type); try a.encode(to: encoder)
        case .markforged(let a): try c.encode("markforged", forKey: .type); try a.encode(to: encoder)
        case .lan(let a): try c.encode("lan", forKey: .type); try a.encode(to: encoder)
        }
    }
}
