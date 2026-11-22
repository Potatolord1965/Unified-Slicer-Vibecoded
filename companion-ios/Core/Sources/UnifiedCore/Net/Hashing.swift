import Compression
import CryptoKit
import Foundation

/// MD5 of a file, read in chunks.
public func md5(file url: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var digest = Insecure.MD5()
    while true {
        let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
        if chunk.isEmpty { break }
        digest.update(data: chunk)
    }
    return Data(digest.finalize())
}

public func md5(_ data: Data) -> Data { Data(Insecure.MD5.hash(data: data)) }

public func hmacSHA1(key: Data, message: Data) -> Data {
    Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key)))
}

extension Data {
    public func hex(upper: Bool = false) -> String {
        let digits = Array((upper ? "0123456789ABCDEF" : "0123456789abcdef").utf8)
        var out = [UInt8]()
        out.reserveCapacity(count * 2)
        for b in self {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Decodes base64 or base64url, with or without padding.
    public init?(base64Lenient text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }

    /// base64url without padding.
    public var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// CRC-32 (IEEE), as gzip uses it.
public struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public private(set) var value: UInt32 = 0
    public init() {}

    public mutating func update(_ data: Data) {
        var c = ~value
        for b in data { c = Self.table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        value = ~c
    }

    public static func of(_ data: Data) -> UInt32 {
        var c = CRC32()
        c.update(data)
        return c.value
    }
}

/// Gzips `source` into `destination`, streaming.
public func gzip(_ source: URL, to destination: URL) throws {
    FileManager.default.createFile(atPath: destination.path, contents: nil)
    let output = try FileHandle(forWritingTo: destination)
    defer { try? output.close() }
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }

    // Header: magic, deflate, no flags, no time, no extra flags, unknown OS.
    output.write(Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF]))
    var crc = CRC32()
    var size: UInt32 = 0
    // Apple's zlib filter writes raw DEFLATE, which is what gzip wraps.
    let filter = try OutputFilter(.compress, using: .zlib) { chunk in
        if let chunk = chunk { output.write(chunk) }
    }
    while true {
        let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
        if chunk.isEmpty { break }
        crc.update(chunk)
        size = size &+ UInt32(truncatingIfNeeded: chunk.count)
        try filter.write(chunk)
    }
    try filter.finalize()
    var trailer = Data()
    for v in [crc.value, size] {
        trailer.append(UInt8(v & 0xFF))
        trailer.append(UInt8((v >> 8) & 0xFF))
        trailer.append(UInt8((v >> 16) & 0xFF))
        trailer.append(UInt8((v >> 24) & 0xFF))
    }
    output.write(trailer)
}

/// RFC 1123 date for HTTP headers, e.g. "Tue, 10 Nov 2026 04:05:06 GMT".
public func httpDate(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "GMT")
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return f.string(from: date)
}
