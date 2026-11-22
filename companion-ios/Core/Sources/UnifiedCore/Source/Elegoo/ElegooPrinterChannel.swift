import Foundation

/// Request/response with one printer over Elegoo's cloud messaging, as in the desktop app's
/// PrinterChannel: {"id", "method", "params"} to the user "<agora user id><serial>", replies
/// matched by id, download progress pushed as method 6006.
public final class ElegooPrinterChannel: @unchecked Sendable {
    public static let agoraAppId = "d035320941e34cd5bc4ec106eff05580" // public, from Elegoo's open-source elegoo-link
    public static let mStartPrint = 1020
    public static let mPausePrint = 1021
    public static let mStopPrint = 1022
    public static let mResumePrint = 1023
    public static let mHome = 1026
    public static let mMove = 1027
    public static let mSetTemperature = 1028
    public static let mDownloadFile = 1057
    public static let mCancelDownload = 1058
    public static let mDownloadProgress = 6006

    private let printerUser: String
    private let session = Locked<RtmSession?>(nil)
    private let nextId = Locked(Int(Date().timeIntervalSince1970) % 100_000 * 10)
    private let replies = Locked([Int: JSON]())
    private let waiting = Locked(Set<Int>())
    private let latestDownload = Locked<JSON?>(nil)

    private init(printerUser: String) { self.printerUser = printerUser }

    /// Latest 6006 result: {progress, status} with status 1 done, 2 cancelled, 3 failed.
    public var download: JSON? {
        get { latestDownload.current }
        set { latestDownload.set(newValue) }
    }

    func onMessage(publisher: String, body: String) {
        if !publisher.isEmpty && publisher != printerUser { return }
        guard let msg = JSON.parse(body), msg.objectValue != nil else { return }
        if msg.int("method") == Self.mDownloadProgress {
            latestDownload.set(msg.obj("result"))
        } else if let id = msg.int("id"), waiting.current.contains(id) {
            replies.with { $0[id] = msg }
        }
    }

    @discardableResult
    public func request(_ method: Int, _ params: JSON = .object([:]), timeout: Int = 10, needReply: Bool = true) async throws -> JSON? {
        let id = nextId.with { n -> Int in
            n += 1
            return n
        }
        if needReply { waiting.with { _ = $0.insert(id) } }
        defer {
            waiting.with { _ = $0.remove(id) }
            replies.with { $0[id] = nil }
        }
        let msg: JSON = .object(["id": .integer(id), "method": .integer(method), "params": params])
        guard let s = session.current else { throw IOError("Not connected to Elegoo messaging") }
        try await s.publish(peer: printerUser, message: msg.serialized)
        if !needReply { return nil }
        guard let reply = try await poll(timeout: Double(timeout), every: 0.1, { self.replies.current[id] }) else {
            throw IOError("The printer did not answer within \(timeout) s. Is it online?")
        }
        let code = reply.obj("result").int("error_code") ?? 0
        if code != 0 { throw ElegooPrinterError(code: code, method: method) }
        return reply
    }

    public func close() {
        let s: RtmSession? = session.with { s in
            let old = s
            s = nil
            return old
        }
        s?.close()
    }

    public static func open(rtm: RtmConnector, agoraUserId: String, rtmUserId: String, rtmToken: String, serial: String) async throws -> ElegooPrinterChannel {
        let ch = ElegooPrinterChannel(printerUser: agoraUserId + serial)
        let s = try await rtm.connect(appId: agoraAppId, userId: rtmUserId, token: rtmToken) { [weak ch] publisher, body in
            ch?.onMessage(publisher: publisher, body: body)
        }
        ch.session.set(s)
        return ch
    }
}

public struct ElegooPrinterError: LocalizedError, Sendable {
    public let code: Int
    public let message: String

    public init(code: Int, method: Int) {
        self.code = code
        switch code {
        case 1009: message = "The printer is busy (error 1009)"
        case 1010: message = "The printer is not printing (error 1010)"
        case 1026: message = "The printer has no bed mesh yet (error 1026)"
        default: message = "The printer refused the request (method \(method), error \(code))"
        }
    }

    public var errorDescription: String? { message }
}

/// The printer method and params for `command`, the same over the cloud and the local network.
public func elegooRequest(_ command: PrinterCommand) throws -> (Int, JSON) {
    switch command {
    case .pause: return (ElegooPrinterChannel.mPausePrint, .object([:]))
    case .resume: return (ElegooPrinterChannel.mResumePrint, .object([:]))
    case .stop: return (ElegooPrinterChannel.mStopPrint, .object([:]))
    case .setNozzle(let c): return (ElegooPrinterChannel.mSetTemperature, .object(["extruder": .integer(c)]))
    case .setBed(let c): return (ElegooPrinterChannel.mSetTemperature, .object(["heater_bed": .integer(c)]))
    case .home: return (ElegooPrinterChannel.mHome, .object(["homed_axes": .string("xyz")]))
    case .move(let axis, let mm): return (ElegooPrinterChannel.mMove, .object(["axes": .string(axis.rawValue), "distance": .decimal(mm)]))
    case .light, .speed: throw IOError("Not available on Elegoo printers from this app")
    }
}
