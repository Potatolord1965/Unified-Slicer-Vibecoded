import Foundation

/// Loosely typed JSON, as printer clouds send it. Numbers keep the text they were sent as, so an
/// error code or id reads back exactly; the accessors below are as lenient as the Android app's.
public enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public static func integer<T: BinaryInteger>(_ value: T) -> JSON { .number(String(value)) }
    public static func decimal(_ value: Double) -> JSON { .number(value.isFinite ? "\(value)" : "0") }

    // MARK: Reading

    public subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var objectValue: [String: JSON]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var arrayValue: [JSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// The text of a string, number or boolean.
    public var primitiveText: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    /// A number, or a string holding one.
    public var asNumber: Double? {
        if case .bool = self { return nil }
        guard let t = primitiveText else { return nil }
        return Double(t.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The value at `key`, unless it is missing or null.
    public func el(_ key: String) -> JSON? {
        guard let v = self[key] else { return nil }
        if case .null = v { return nil }
        return v
    }

    public func obj(_ key: String) -> JSON? {
        if case .object? = self[key] { return self[key] }
        return nil
    }

    public func arr(_ key: String) -> [JSON]? { self[key]?.arrayValue }

    /// A primitive's text, nil when missing, empty or not a primitive.
    public func str(_ key: String) -> String? {
        guard let t = el(key)?.primitiveText, !t.isEmpty else { return nil }
        return t
    }

    public func num(_ key: String) -> Double? { el(key)?.asNumber }
    public func long(_ key: String) -> Int64? { num(key).flatMap(JSON.toInt64) }
    public func int(_ key: String) -> Int? { long(key).map { Int(clamping: $0) } }

    public func bool(_ key: String) -> Bool? {
        guard let t = el(key)?.primitiveText else { return nil }
        if t == "true" { return true }
        if t == "false" { return false }
        return Int64(t).map { $0 != 0 }
    }

    /// Truncates toward zero like Kotlin's toLong(), nil for NaN and infinities.
    public static func toInt64(_ d: Double) -> Int64? {
        guard d.isFinite else { return nil }
        if d >= 9.2e18 { return Int64.max }
        if d <= -9.2e18 { return Int64.min }
        return Int64(d.rounded(.towardZero))
    }

    /// Recursively merges `delta` into `base`; objects merge, everything else replaces.
    public static func merge(_ base: [String: JSON], _ delta: [String: JSON]) -> [String: JSON] {
        var out = base
        for (k, v) in delta {
            if case .object(let old)? = out[k], case .object(let new) = v {
                out[k] = .object(merge(old, new))
            } else {
                out[k] = v
            }
        }
        return out
    }

    // MARK: Writing

    /// Compact JSON text, keys sorted.
    public var serialized: String {
        var s = ""
        write(&s)
        return s
    }

    private func write(_ s: inout String) {
        switch self {
        case .null: s += "null"
        case .bool(let b): s += b ? "true" : "false"
        case .number(let n): s += n
        case .string(let t): JSON.quote(t, into: &s)
        case .array(let a):
            s += "["
            for (i, v) in a.enumerated() {
                if i > 0 { s += "," }
                v.write(&s)
            }
            s += "]"
        case .object(let o):
            s += "{"
            for (i, key) in o.keys.sorted().enumerated() {
                if i > 0 { s += "," }
                JSON.quote(key, into: &s)
                s += ":"
                o[key]?.write(&s)
            }
            s += "}"
        }
    }

    static func quote(_ t: String, into s: inout String) {
        s += "\""
        for u in t.unicodeScalars {
            switch u {
            case "\"": s += "\\\""
            case "\\": s += "\\\\"
            case "\n": s += "\\n"
            case "\r": s += "\\r"
            case "\t": s += "\\t"
            default:
                if u.value < 0x20 {
                    let hex = String(u.value, radix: 16)
                    s += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    s.unicodeScalars.append(u)
                }
            }
        }
        s += "\""
    }

    // MARK: Parsing

    public static func parse(_ text: String) -> JSON? { parse(Data(text.utf8)) }

    /// Parses JSON text; nil when it isn't JSON.
    public static func parse(_ data: Data) -> JSON? {
        var p = Parser(bytes: [UInt8](data))
        if p.bytes.count >= 3, p.bytes[0] == 0xEF, p.bytes[1] == 0xBB, p.bytes[2] == 0xBF { p.i = 3 }
        guard let v = try? p.value(depth: 0) else { return nil }
        p.skipSpace()
        return p.i == p.bytes.count ? v : nil
    }
}

extension JSON: CustomStringConvertible {
    public var description: String { serialized }
}

extension JSON: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSON: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(String(value)) }
}

extension JSON: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .decimal(value) }
}

extension JSON: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSON: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
}

extension JSON: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

private struct Parser {
    struct Bad: Error {}

    let bytes: [UInt8]
    var i = 0

    mutating func skipSpace() {
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A || bytes[i] == 0x0D { i += 1 }
    }

    mutating func value(depth: Int) throws -> JSON {
        guard depth < 512 else { throw Bad() }
        skipSpace()
        guard i < bytes.count else { throw Bad() }
        switch bytes[i] {
        case 0x7B: return try object(depth)
        case 0x5B: return try array(depth)
        case 0x22: return .string(try string())
        case 0x74: try literal("true"); return .bool(true)
        case 0x66: try literal("false"); return .bool(false)
        case 0x6E: try literal("null"); return .null
        default: return .number(try number())
        }
    }

    mutating func literal(_ word: String) throws {
        for b in word.utf8 {
            guard i < bytes.count, bytes[i] == b else { throw Bad() }
            i += 1
        }
    }

    mutating func number() throws -> String {
        let start = i
        while i < bytes.count {
            let c = bytes[i]
            let isNumberChar = (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x2B || c == 0x2E || c == 0x65 || c == 0x45
            if !isNumberChar { break }
            i += 1
        }
        guard i > start else { throw Bad() }
        let text = String(decoding: bytes[start..<i], as: UTF8.self)
        guard Double(text) != nil else { throw Bad() }
        return text
    }

    mutating func hex4() throws -> UInt32 {
        guard i + 4 <= bytes.count else { throw Bad() }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = bytes[i]
            i += 1
            let d: UInt32
            switch c {
            case 0x30...0x39: d = UInt32(c - 0x30)
            case 0x41...0x46: d = UInt32(c - 0x41 + 10)
            case 0x61...0x66: d = UInt32(c - 0x61 + 10)
            default: throw Bad()
            }
            v = v << 4 | d
        }
        return v
    }

    mutating func string() throws -> String {
        i += 1 // opening quote
        var out = [UInt8]()
        while true {
            guard i < bytes.count else { throw Bad() }
            let c = bytes[i]
            i += 1
            if c == 0x22 { break }
            if c != 0x5C {
                out.append(c)
                continue
            }
            guard i < bytes.count else { throw Bad() }
            let e = bytes[i]
            i += 1
            switch e {
            case 0x22, 0x5C, 0x2F: out.append(e)
            case 0x62: out.append(0x08)
            case 0x66: out.append(0x0C)
            case 0x6E: out.append(0x0A)
            case 0x72: out.append(0x0D)
            case 0x74: out.append(0x09)
            case 0x75:
                var scalar = try hex4()
                if scalar >= 0xD800 && scalar < 0xDC00, i + 1 < bytes.count, bytes[i] == 0x5C, bytes[i + 1] == 0x75 {
                    let save = i
                    i += 2
                    let low = try hex4()
                    if low >= 0xDC00 && low < 0xE000 {
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        i = save
                    }
                }
                let replacement: Unicode.Scalar = "\u{FFFD}"
                let u = Unicode.Scalar(scalar) ?? replacement
                out.append(contentsOf: Array(String(Character(u)).utf8))
            default:
                throw Bad()
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    mutating func array(_ depth: Int) throws -> JSON {
        i += 1
        var out = [JSON]()
        skipSpace()
        if i < bytes.count, bytes[i] == 0x5D {
            i += 1
            return .array(out)
        }
        while true {
            out.append(try value(depth: depth + 1))
            skipSpace()
            guard i < bytes.count else { throw Bad() }
            if bytes[i] == 0x2C { i += 1; continue }
            if bytes[i] == 0x5D { i += 1; return .array(out) }
            throw Bad()
        }
    }

    mutating func object(_ depth: Int) throws -> JSON {
        i += 1
        var out = [String: JSON]()
        skipSpace()
        if i < bytes.count, bytes[i] == 0x7D {
            i += 1
            return .object(out)
        }
        while true {
            skipSpace()
            guard i < bytes.count, bytes[i] == 0x22 else { throw Bad() }
            let key = try string()
            skipSpace()
            guard i < bytes.count, bytes[i] == 0x3A else { throw Bad() }
            i += 1
            out[key] = try value(depth: depth + 1)
            skipSpace()
            guard i < bytes.count else { throw Bad() }
            if bytes[i] == 0x2C { i += 1; continue }
            if bytes[i] == 0x7D { i += 1; return .object(out) }
            throw Bad()
        }
    }
}

/// The lenient accessors on a value that may be missing, so lookups chain like the Android app's.
extension Optional where Wrapped == JSON {
    public func el(_ key: String) -> JSON? { self?.el(key) }
    public func obj(_ key: String) -> JSON? { self?.obj(key) }
    public func arr(_ key: String) -> [JSON]? { self?.arr(key) }
    public func str(_ key: String) -> String? { self?.str(key) }
    public func num(_ key: String) -> Double? { self?.num(key) }
    public func long(_ key: String) -> Int64? { self?.long(key) }
    public func int(_ key: String) -> Int? { self?.int(key) }
    public func bool(_ key: String) -> Bool? { self?.bool(key) }
}

extension JSON {
    /// `delta` merged into `base` when both are objects, else `delta`.
    public static func merged(_ base: JSON?, _ delta: JSON) -> JSON {
        if case .object(let old)? = base, case .object(let new) = delta { return .object(merge(old, new)) }
        return delta
    }
}
