import Foundation
import Network
import Security

/// The other side ended the connection.
public struct ConnectionClosed: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// How a socket is secured.
public enum TLSMode: Sendable, Equatable {
    case none
    /// The system's certificate and host name checks.
    case system
    /// A Bambu printer reached by address: Bambu's CA and the printer's serial number.
    case bambu(serial: String)
}

/// A TCP (or TLS) connection on Network.framework with async reads and writes.
public final class NetConnection: @unchecked Sendable {
    public let host: String
    public let port: UInt16
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let certificateProblem = Locked<String?>(nil)

    public init(host: String, port: UInt16, tls: TLSMode, connectTimeout: Int = 10) {
        self.host = host
        self.port = port
        queue = DispatchQueue(label: "net.\(host).\(port)")
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = connectTimeout
        tcp.noDelay = true
        let params: NWParameters
        switch tls {
        case .none:
            params = NWParameters(tls: nil, tcp: tcp)
        case .system:
            params = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
        case .bambu(let serial):
            let options = NWProtocolTLS.Options()
            let problem = certificateProblem
            let verifyQueue = DispatchQueue(label: "net.verify")
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                let reason = bambuTrustProblem(trust, serial: serial)
                problem.set(reason)
                complete(reason == nil)
            }, verifyQueue)
            params = NWParameters(tls: options, tcp: tcp)
        }
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? .any
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: params)
    }

    private var address: String { "\(host):\(port)" }

    private func failure(_ error: NWError?) -> Error {
        if let p = certificateProblem.current { return CertificateError(p) }
        switch error {
        case .posix(let code)? where code == .ECONNREFUSED:
            return IOError("Could not connect to \(address): connection refused")
        case .posix(let code)? where code == .ETIMEDOUT:
            return IOError("\(address) did not answer in time")
        case .dns?:
            return IOError("Could not find \(host)")
        case .tls?:
            return IOError("Could not make a secure connection to \(address)")
        case let e?:
            return IOError("Could not connect to \(address): \(e.localizedDescription)")
        case nil:
            return IOError("Could not connect to \(address)")
        }
    }

    /// Connects; throws when the device can't be reached within `timeout` seconds.
    public func start(timeout: Double = 12) async throws {
        let conn = connection
        try await bridge(timeout: timeout, timeoutMessage: "\(address) did not answer in time", onEnd: { conn.cancel() }) { (r: Resumer<Void>) in
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    r.succeed(())
                case .failed(let e):
                    r.fail(self?.failure(e) ?? IOError("Connection failed"))
                case .waiting(let e):
                    // No route, refused or no network: don't wait for it to change.
                    r.fail(self?.failure(e) ?? IOError("Connection failed"))
                    conn.cancel()
                case .cancelled:
                    r.fail(self?.failure(nil) ?? IOError("Connection closed"))
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    public func send(_ data: Data) async throws {
        let conn = connection
        let label = address
        try await bridge(timeout: 30, timeoutMessage: "Sending to \(label) timed out", onEnd: { conn.cancel() }) { (r: Resumer<Void>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let e = error { r.fail(IOError("Could not send to \(label): \(e.localizedDescription)")) } else { r.succeed(()) }
            })
        }
    }

    /// The next bytes received, at most `max`. Throws at the end of the stream. A receive that
    /// times out or is cancelled leaves the connection unusable: cancel it then.
    public func receive(max: Int = 65536, timeout: Double? = nil) async throws -> Data {
        let conn = connection
        let label = address
        return try await bridge(timeout: timeout, timeoutMessage: "\(label) stopped answering") { (r: Resumer<Data>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, isComplete, error in
                if let d = data, !d.isEmpty {
                    r.succeed(d)
                } else if let e = error {
                    r.fail(IOError("The connection to \(label) failed: \(e.localizedDescription)"))
                } else if isComplete {
                    r.fail(ConnectionClosed("\(label) closed the connection"))
                } else {
                    r.fail(IOError("No data from \(label)"))
                }
            }
        }
    }

    /// Exactly `count` bytes.
    public func receive(exactly count: Int, timeout: Double? = nil) async throws -> Data {
        var out = Data()
        while out.count < count {
            out.append(try await receive(max: count - out.count, timeout: timeout))
        }
        return out
    }

    public func cancel() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}
