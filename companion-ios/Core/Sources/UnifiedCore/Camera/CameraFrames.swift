import Foundation

/// Finds JPEG pictures (FF D8 … FF D9) in a byte stream, such as an MJPEG stream.
public struct JPEGScanner {
    private var inFrame = false
    private var prev: UInt8 = 0
    private var frame = Data()
    private let maxBytes: Int

    public init(maxBytes: Int = 8 << 20) { self.maxBytes = maxBytes }

    /// Feeds one byte; returns a picture when this byte completes one.
    public mutating func feed(_ b: UInt8) throws -> Data? {
        if !inFrame {
            if prev == 0xFF && b == 0xD8 {
                inFrame = true
                frame = Data([0xFF, 0xD8])
                prev = 0
            } else {
                prev = b
            }
            return nil
        }
        frame.append(b)
        if prev == 0xFF && b == 0xD9 {
            inFrame = false
            prev = 0
            let done = frame
            frame = Data()
            return done
        }
        prev = b
        if frame.count >= maxBytes { throw IOError("The camera sent an oversized picture") }
        return nil
    }

    /// Every complete picture in `data`.
    public mutating func feed(_ data: Data) throws -> [Data] {
        var out = [Data]()
        for b in data { if let f = try feed(b) { out.append(f) } }
        return out
    }
}

/// 80 bytes: 0x40, 0x3000, 0, 0 (little endian), then user "bblp" and the access code, each padded to 32 bytes.
public func bambuAuthPacket(_ accessCode: String) -> Data {
    var out = Data()
    for v: UInt32 in [0x40, 0x3000, 0, 0] {
        out.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }
    func padded(_ s: String) -> [UInt8] {
        let bytes = Array(s.utf8.prefix(32))
        return bytes + [UInt8](repeating: 0, count: 32 - bytes.count)
    }
    out.append(contentsOf: padded("bblp"))
    out.append(contentsOf: padded(accessCode))
    return out
}

/// Pictures (JPEG or PNG bytes) from `feed`, until the consumer stops. Throws when the camera cannot be reached.
public func cameraFrames(_ feed: CameraFeed) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                switch feed {
                case .http(let url, let headers):
                    try await httpFrames(url, headers) { continuation.yield($0) }
                case .bambuJpeg(let host, let code, let serial):
                    try await bambuFrames(host, code, serial) { continuation.yield($0) }
                case .bambuRtsp:
                    throw IOError("This printer streams its camera as RTSP video, which this app can't show yet. Use Bambu Handy to watch it.")
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

private func httpFrames(_ url: String, _ headers: [String: String], _ emit: (Data) -> Void) async throws {
    guard let u = URL(string: url) else { throw IOError("Not a valid camera address: \(url)") }
    let config = URLSessionConfiguration.ephemeral
    // A stream stays open for as long as it is watched.
    config.timeoutIntervalForRequest = 20
    config.timeoutIntervalForResource = 7 * 24 * 3600
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: u)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
    while true {
        try Task.checkCancellation()
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let e as URLError {
            if e.code == .cancelled { throw CancellationError() }
            throw IOError(URLSessionHTTP.describe(e, host: u.host))
        }
        guard let http = response as? HTTPURLResponse else { throw IOError("The camera sent no picture") }
        guard (200..<300).contains(http.statusCode) else { throw IOError("The camera answered HTTP \(http.statusCode)") }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if type.hasPrefix("multipart") {
            var scanner = JPEGScanner()
            for try await b in bytes {
                if let frame = try scanner.feed(b) { emit(frame) }
            }
        } else {
            var data = Data()
            for try await b in bytes {
                data.append(b)
                if data.count > 16 << 20 { throw IOError("The camera sent an oversized picture") }
            }
            emit(data)
        }
        try await pause(1)
    }
}

private func bambuFrames(_ host: String, _ accessCode: String, _ serial: String, _ emit: (Data) -> Void) async throws {
    let conn = NetConnection(host: host, port: 6000, tls: .bambu(serial: serial), connectTimeout: 8)
    defer { conn.cancel() }
    do {
        try await conn.start(timeout: 10)
        try await conn.send(bambuAuthPacket(accessCode))
        while true {
            let header = [UInt8](try await conn.receive(exactly: 16, timeout: 20))
            let size = Int(Int32(bitPattern: UInt32(header[0]) | UInt32(header[1]) << 8 | UInt32(header[2]) << 16 | UInt32(header[3]) << 24))
            guard size > 0, size <= 8 << 20 else { throw IOError("The printer rejected the camera connection. Check the access code.") }
            emit(try await conn.receive(exactly: size, timeout: 20))
        }
    } catch is ConnectionClosed {
        throw IOError("The printer closed the camera connection. Check the access code.")
    }
}
