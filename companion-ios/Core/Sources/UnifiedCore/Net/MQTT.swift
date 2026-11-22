import Foundation

/// MQTT 3.1.1 packets, as far as a client that subscribes and publishes at QoS 0 needs them.
public enum MQTTPacket: Equatable, Sendable {
    case connAck(returnCode: UInt8)
    case publish(topic: String, payload: Data, qos: UInt8, packetId: UInt16?)
    case pubAck(packetId: UInt16)
    case subAck(packetId: UInt16)
    case pingResp
    case other(type: UInt8)

    // MARK: Encoding

    static func string(_ s: String) -> Data {
        let bytes = Data(s.utf8)
        return Data([UInt8(bytes.count >> 8 & 0xFF), UInt8(bytes.count & 0xFF)]) + bytes
    }

    static func remainingLength(_ n: Int) -> Data {
        var out = Data()
        var x = n
        repeat {
            var byte = UInt8(x % 128)
            x /= 128
            if x > 0 { byte |= 0x80 }
            out.append(byte)
        } while x > 0
        return out
    }

    static func packet(_ header: UInt8, _ body: Data) -> Data {
        Data([header]) + remainingLength(body.count) + body
    }

    public static func connect(clientId: String, username: String?, password: String?, keepAlive: UInt16, cleanSession: Bool = true) -> Data {
        var flags: UInt8 = cleanSession ? 0x02 : 0
        if username != nil { flags |= 0x80 }
        if password != nil { flags |= 0x40 }
        var body = string("MQTT")
        body.append(4)
        body.append(flags)
        body.append(UInt8(keepAlive >> 8))
        body.append(UInt8(keepAlive & 0xFF))
        body += string(clientId)
        if let u = username { body += string(u) }
        if let p = password { body += string(p) }
        return packet(0x10, body)
    }

    public static func subscribe(packetId: UInt16, topics: [String]) -> Data {
        var body = Data([UInt8(packetId >> 8), UInt8(packetId & 0xFF)])
        for t in topics {
            body += string(t)
            body.append(0)
        }
        return packet(0x82, body)
    }

    public static func publish(topic: String, payload: Data) -> Data {
        packet(0x30, string(topic) + payload)
    }

    public static func pubAck(_ packetId: UInt16) -> Data {
        Data([0x40, 0x02, UInt8(packetId >> 8), UInt8(packetId & 0xFF)])
    }

    public static let pingReq = Data([0xC0, 0x00])
    public static let disconnect = Data([0xE0, 0x00])

    // MARK: Decoding

    /// Decodes one packet's type byte and body.
    public static func decode(header: UInt8, body: Data) throws -> MQTTPacket {
        let b = [UInt8](body)
        func u16(_ i: Int) throws -> UInt16 {
            guard i + 1 < b.count else { throw IOError("Malformed MQTT packet") }
            return UInt16(b[i]) << 8 | UInt16(b[i + 1])
        }
        switch header >> 4 {
        case 2:
            guard b.count >= 2 else { throw IOError("Malformed MQTT packet") }
            return .connAck(returnCode: b[1])
        case 3:
            let qos = (header >> 1) & 0x03
            let len = Int(try u16(0))
            guard 2 + len <= b.count else { throw IOError("Malformed MQTT packet") }
            let topic = String(decoding: b[2..<(2 + len)], as: UTF8.self)
            var i = 2 + len
            var id: UInt16?
            if qos > 0 {
                id = try u16(i)
                i += 2
            }
            return .publish(topic: topic, payload: Data(b[min(i, b.count)...]), qos: qos, packetId: id)
        case 4: return .pubAck(packetId: try u16(0))
        case 9: return .subAck(packetId: try u16(0))
        case 13: return .pingResp
        default: return .other(type: header >> 4)
        }
    }
}

/// Reads whole MQTT packets from a connection.
struct MQTTReader {
    let connection: NetConnection
    var buffer = Data()
    static let maxPacket = 16 * 1024 * 1024

    init(_ connection: NetConnection) { self.connection = connection }

    private mutating func fill(_ n: Int, timeout: Double?) async throws {
        while buffer.count < n {
            buffer.append(try await connection.receive(max: 256 * 1024, timeout: timeout))
        }
    }

    mutating func next(timeout: Double?) async throws -> MQTTPacket {
        try await fill(2, timeout: timeout)
        var length = 0
        var multiplier = 1
        var i = 1
        while true {
            try await fill(i + 1, timeout: timeout)
            let byte = buffer[buffer.startIndex + i]
            length += Int(byte & 0x7F) * multiplier
            i += 1
            if byte & 0x80 == 0 { break }
            multiplier *= 128
            if i > 4 { throw IOError("Malformed MQTT packet") }
        }
        guard length <= Self.maxPacket else { throw IOError("MQTT message too large") }
        try await fill(i + length, timeout: timeout)
        let header = buffer[buffer.startIndex]
        let body = buffer.subdata(in: (buffer.startIndex + i)..<(buffer.startIndex + i + length))
        buffer = Data(buffer.dropFirst(i + length))
        return try MQTTPacket.decode(header: header, body: body)
    }
}

/// A kept-open MQTT connection. Subscribes `topics` on every connect and then calls `onConnected`,
/// e.g. to ask the printer for a full status. A dropped connection is made again by the next
/// `ensureConnected`.
public final class MQTTLink: @unchecked Sendable {
    public let host: String
    public let port: UInt16
    private let tls: TLSMode
    private let username: String
    private let password: String
    private let topics: [String]
    private let clientId: String
    private let keepAlive: UInt16
    private let onConnected: @Sendable (MQTTLink) -> Void
    private let onMessage: @Sendable (String, Data) -> Void

    private struct State {
        var connection: NetConnection?
        var connecting: Task<Void, Error>?
        var tasks: [Task<Void, Never>] = []
        var closed = false
    }

    private let state = Locked(State())

    public init(
        host: String, port: UInt16, tls: TLSMode, username: String, password: String, topics: [String],
        clientId: String = "usc-" + randomId(12), keepAlive: UInt16 = 30,
        onConnected: @escaping @Sendable (MQTTLink) -> Void = { _ in },
        onMessage: @escaping @Sendable (String, Data) -> Void
    ) {
        self.host = host
        self.port = port
        self.tls = tls
        self.username = username
        self.password = password
        self.topics = topics
        self.clientId = clientId
        self.keepAlive = keepAlive
        self.onConnected = onConnected
        self.onMessage = onMessage
    }

    public var isConnected: Bool { state.current.connection != nil }

    /// Connects if not connected. Throws on failure; a bad user name or password becomes `AuthError`.
    public func ensureConnected() async throws {
        let task: Task<Void, Error>? = try state.with { s in
            if s.closed { throw IOError("The connection is closed") }
            if s.connection != nil { return nil }
            if s.connecting == nil {
                s.connecting = Task { [self] in
                    defer { state.with { $0.connecting = nil } }
                    try await connect()
                }
            }
            return s.connecting
        }
        try await task?.value
    }

    private func connect() async throws {
        let conn = NetConnection(host: host, port: port, tls: tls)
        do {
            try await conn.start(timeout: 12)
            try await conn.send(MQTTPacket.connect(clientId: clientId, username: username, password: password, keepAlive: keepAlive))
            var reader = MQTTReader(conn)
            let ack = try await reader.next(timeout: 12)
            guard case .connAck(let rc) = ack else { throw IOError("Unexpected reply from \(host)") }
            switch rc {
            case 0: break
            case 4, 5: throw AuthError("The printer or broker rejected the credentials")
            default: throw IOError("\(host) refused the connection (code \(rc))")
            }
            if !topics.isEmpty { try await conn.send(MQTTPacket.subscribe(packetId: 1, topics: topics)) }
            let primed = reader
            let started: Bool = state.with { s in
                if s.closed { return false }
                s.connection = conn
                s.tasks.forEach { $0.cancel() }
                s.tasks = [
                    Task { [weak self] in await self?.readLoop(conn, primed) },
                    Task { [weak self] in await self?.pingLoop(conn) },
                ]
                return true
            }
            guard started else { throw IOError("The connection is closed") }
        } catch {
            conn.cancel()
            if error is CancellationError || error is AuthError || error is CertificateError { throw error }
            if let e = error as? IOError { throw e }
            throw IOError("Could not connect to \(host): \(readable(error))")
        }
        onConnected(self)
    }

    private func dropped(_ conn: NetConnection) {
        conn.cancel()
        state.with { s in
            if s.connection === conn { s.connection = nil }
        }
    }

    private func readLoop(_ conn: NetConnection, _ start: MQTTReader) async {
        var reader = start
        let silence = Double(keepAlive) * 2 + 5
        do {
            while !Task.isCancelled {
                let packet = try await reader.next(timeout: silence)
                if case .publish(let topic, let payload, let qos, let id) = packet {
                    if qos > 0, let id = id { try? await conn.send(MQTTPacket.pubAck(id)) }
                    onMessage(topic, payload)
                }
            }
        } catch {}
        dropped(conn)
    }

    private func pingLoop(_ conn: NetConnection) async {
        while !Task.isCancelled {
            do {
                try await pause(Double(keepAlive))
                try await conn.send(MQTTPacket.pingReq)
            } catch {
                break
            }
        }
    }

    private func current() throws -> NetConnection {
        guard let c = state.current.connection else { throw IOError("Not connected to \(host)") }
        return c
    }

    /// Fire and forget, for status requests.
    public func publish(_ topic: String, _ payload: String) {
        guard let c = try? current() else { return }
        let packet = MQTTPacket.publish(topic: topic, payload: Data(payload.utf8))
        Task { try? await c.send(packet) }
    }

    /// Publishes and waits until the message has gone out; throws when it couldn't be sent.
    public func send(_ topic: String, _ payload: String) async throws {
        let c = try current()
        do {
            try await c.send(MQTTPacket.publish(topic: topic, payload: Data(payload.utf8)))
        } catch {
            dropped(c)
            throw IOError("Could not send to \(host): \(readable(error))")
        }
    }

    public func close() {
        let (conn, tasks, connecting): (NetConnection?, [Task<Void, Never>], Task<Void, Error>?) = state.with { s in
            s.closed = true
            let out = (s.connection, s.tasks, s.connecting)
            s.connection = nil
            s.tasks = []
            return out
        }
        connecting?.cancel()
        tasks.forEach { $0.cancel() }
        if let c = conn {
            Task {
                try? await c.send(MQTTPacket.disconnect)
                c.cancel()
            }
        }
    }
}
