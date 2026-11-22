import Foundation

/// Creality Cloud REST API, ported from Unified Slicer's CrealityCloud client (from Creality Print 6).
public struct CrealityApi: Sendable {
    let http: HTTPClient
    let region: String
    let deviceUid: String

    public init(_ http: HTTPClient, region: String, deviceUid: String) {
        self.http = http
        self.region = region
        self.deviceUid = deviceUid
    }

    var base: String { region == "china" ? "https://api.crealitycloud.cn" : "https://api.crealitycloud.com" }

    private func headers(_ session: CrealityAccount?) -> [String: String] {
        var h = [
            "__CXY_APP_ID_": "creality_model",
            "__CXY_PLATFORM_": "11",
            "__CXY_OS_LANG_": "0",
            "__CXY_OS_VER_": "win",
            "__CXY_DUID_": deviceUid,
            "__CXY_REQUESTID_": UUID().uuidString.lowercased(),
        ]
        if let s = session {
            h["__CXY_UID_"] = s.userId
            h["__CXY_TOKEN_"] = s.token
        }
        return h
    }

    public func post(_ path: String, _ body: JSON, session: CrealityAccount? = nil) async throws -> JSON {
        try envelope(try await http.fetchJSON(try .json(base + path, body, headers: headers(session))))
    }

    public func get(_ path: String, session: CrealityAccount?) async throws -> JSON {
        try envelope(try await http.fetchJSON(try HTTPRequest(base + path, headers: headers(session))))
    }

    /// {code, msg, result}: code 0 is success, 4 an expired token.
    private func envelope(_ reply: JSON) throws -> JSON {
        // A bare telemetry map has no envelope.
        if reply.el("code") == nil { return reply }
        let code = reply.int("code")
        switch code {
        case 0: return reply.el("result") ?? .object([:])
        case 4: throw AuthError("Creality sign-in expired")
        default: throw IOError(reply.str("msg") ?? "Creality Cloud error \(code.map(String.init) ?? "?")")
        }
    }

    /// `accountType`: 2 = e-mail, 1 = phone number.
    public func login(accountType: Int, account: String, password: String) async throws -> CrealityAccount {
        let body: JSON = .object(["type": .integer(accountType), "account": .string(account), "password": .string(password)])
        let result: JSON
        do {
            result = try await post("/api/cxy/account/v2/loginV2", body)
        } catch let e as AuthError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            result = try await post("/api/account/loginV2", body) // older path, still answered
        }
        guard let token = result.str("token"), let userId = result.str("userId"), userId != "0" else {
            throw AuthError("Creality Cloud returned no session for this account")
        }
        return CrealityAccount(
            id: "creality-" + UUID().uuidString.lowercased(), label: result.obj("user_info").str("nickName") ?? account,
            region: region, token: token, userId: userId, deviceUid: deviceUid
        )
    }

    public static func newDeviceUid() -> String { UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "") }
}

public final class CrealityCloudSource: PrinterSource, PrintCapable, Controllable, @unchecked Sendable {
    static let via = "Creality Cloud"

    public let creality: CrealityAccount
    private let ctx: SourceContext
    private let api: CrealityApi
    private let tbIds = Locked([String: String]())

    public init(_ account: CrealityAccount, _ ctx: SourceContext) {
        creality = account
        self.ctx = ctx
        api = CrealityApi(ctx.http, region: account.region, deviceUid: account.deviceUid)
    }

    public var account: Account { .creality(creality) }

    public func refresh() async throws -> [PrinterStatus] {
        var devices = [JSON]()
        for page in 1...10 {
            let result = try await api.post("/api/rest/print/cluster/devices/getDevices", .object(["page": .integer(page), "pageSize": .integer(100)]), session: creality)
            let list = result.arr("list") ?? []
            devices += list.filter { [1, 9].contains($0.int("type") ?? 9) }
            if list.count < 100 { break }
        }
        return try await withThrowingTaskGroup(of: (Int, PrinterStatus).self) { group in
            for (i, d) in devices.enumerated() {
                guard let dn = d.str("deviceName") else { continue }
                group.addTask { (i, try await self.status(dn, d)) }
            }
            var out = [(Int, PrinterStatus)]()
            for try await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// As Creality Print: gzip the G-code, PUT it to Creality's Aliyun OSS bucket with the account's
    /// temporary credentials, register it (uploadGcode) and queue it on the printer (addSingleTask).
    public func sendPrint(deviceId: String, job: PrintJob, progress: @escaping SendProgress) async throws {
        progress(0, "Preparing the upload…")
        let empty: JSON = .object([:])
        let aliyun = try await api.post("/api/cxy/account/v2/getAliyunInfo", empty, session: creality).obj("aliyunInfo")
        guard let keyId = aliyun.str("accessKeyId"), let secret = aliyun.str("secretAccessKey") else {
            throw IOError("Creality Cloud returned no upload credentials")
        }
        let sessionToken = aliyun.str("sessionToken")
        let oss = try await api.post("/api/cxy/v2/common/getOssInfo", empty, session: creality).obj("info")
        guard var endpoint = oss.str("endpoint"), let bucket = oss.obj("file").str("bucket") else {
            throw IOError("Creality Cloud returned no storage location")
        }
        if let r = endpoint.range(of: "://") { endpoint = String(endpoint[r.upperBound...]) }
        while endpoint.hasSuffix("/") { endpoint.removeLast() }

        var display = job.name
        for suffix in [".gcode", ".GCODE"] where display.hasSuffix(suffix) { display.removeLast(suffix.count) }
        if display.isEmpty { display = "unnamed" }
        let key = Self.objectKey(display, try md5(file: job.file).hex())
        let gz = FileManager.default.temporaryDirectory.appendingPathComponent("creality-upload-\(randomId(8)).gcode.gz")
        defer { try? FileManager.default.removeItem(at: gz) }
        try gzip(job.file, to: gz)

        progress(0, "Uploading to Creality Cloud…")
        let contentType = "application/octet-stream"
        let date = httpDate(Date())
        let ossHeaders = sessionToken.map { "x-oss-security-token:\($0)\n" } ?? ""
        let signature = Self.ossSignature(secret, "PUT\n\n\(contentType)\n\(date)\n\(ossHeaders)/\(bucket)/\(key)")
        let size = max(fileSize(gz), 1)
        var headers = [
            "Date": date,
            "Authorization": "OSS \(keyId):\(signature)",
            "Content-Disposition": "attachment;filename=\"\(display).gcode.gz\"",
            "Content-Type": contentType,
        ]
        if let t = sessionToken { headers["x-oss-security-token"] = t }
        _ = try await ctx.http.fetchText(
            try HTTPRequest("https://\(bucket).\(endpoint)/\(key)", method: "PUT", headers: headers, body: .file(gz), isUpload: true),
            onSent: { sent in progress(Int(sent * 100 / size), nil) }
        )

        progress(100, "Starting the print…")
        let uploaded = try await api.post("/api/cxy/v2/gcode/uploadGcode", .object([
            "list": .array([.object(["name": .string(display), "fileKey": .string(key), "type": .integer(1)])]),
        ]), session: creality).arr("list")?.first
        guard let gcodeId = uploaded.str("id") else { throw IOError("Creality Cloud did not register the upload") }
        let fileKey = uploaded.str("filekey") ?? uploaded.str("fileKey") ?? key
        _ = try await api.post("/api/rest/print/cluster/addSingleTask", .object([
            "deviceName": .string(deviceId), "gcodeId": .string(gcodeId), "taskName": .string(display),
            "gcodeFilePath": .string("https://file-cdn.creality.com/\(fileKey)"), "printCount": .integer(1), "modelName": .string(display),
        ]), session: creality)
        progress(100, "Print started")
    }

    /// As Creality Print: {"method":"set","params":{…}} relayed to the printer, which answers.
    public func control(deviceId: String, command: PrinterCommand) async throws {
        if tbIds.current[deviceId] == nil { _ = try await refresh() }
        guard let tbId = tbIds.current[deviceId] else { throw IOError("This printer does not take commands through Creality Cloud") }
        _ = try await api.post("/api/rest/iotrouter/rpc/twoway/\(tbId)", .object(["method": .string("set"), "params": try Self.controlParams(command)]), session: creality)
    }

    private func status(_ dn: String, _ d: JSON) async throws -> PrinterStatus {
        let rawModel = d.str("model") ?? ""
        let model = rawModel.lowercased().hasPrefix("cr-k1") ? String(rawModel.dropFirst(3)) : rawModel
        let name = d.str("aliasName") ?? (model.isEmpty ? dn : model)
        let deviceState = d.int("deviceState") ?? -1
        if deviceState == -1 {
            return PrinterStatus(accountId: creality.id, deviceId: dn, name: name, model: model, brand: .creality, via: Self.via, state: .offline)
        }
        let tbId = d.str("tbId")
        if let id = tbId { tbIds.with { $0[dn] = id } }
        var t: JSON = .object([:])
        if let id = tbId {
            do {
                t = Self.parseTelemetry(try await api.get("/api/rest/iotrouter/\(id)/values/timeseries?keys=&useStrictDataTypes=true", session: creality))
            } catch let e as AuthError {
                throw e
            } catch is CancellationError {
                throw CancellationError()
            } catch {}
        }
        let info = d.obj("printInfo")
        let state = Self.state(t.int("state") ?? deviceState)
        let printing = state.active || state == .finished
        func temp(_ cur: String, _ target: String) -> Temperature? {
            t.num(cur).map { Temperature($0, target: t.num(target).flatMap { $0 > 0 ? $0 : nil }) }
        }
        return PrinterStatus(
            accountId: creality.id, deviceId: dn, name: name, model: model, brand: .creality, via: Self.via, state: state,
            progress: printing ? (t.int("printProgress") ?? info.int("printProgress")) : nil,
            remainingSeconds: (t.long("printLeftTime") ?? info.long("printLeftTime")).flatMap { state.active && $0 > 0 ? $0 : nil },
            layer: printing ? t.int("layer") : nil,
            totalLayers: t.int("TotalLayer").flatMap { printing && $0 > 0 ? $0 : nil },
            file: printing ? (t.str("printFileName") ?? info.str("modelName")) : nil,
            nozzle: temp("nozzleTemp", "targetNozzleTemp"),
            bed: temp("bedTemp0", "targetBedTemp0"),
            chamber: t.num("boxTemp").map { Temperature($0) },
            light: t.int("lightSw").map { $0 != 0 }
        )
    }

    public func close() {}

    public static func controlParams(_ command: PrinterCommand) throws -> JSON {
        switch command {
        case .pause: return .object(["pause": .integer(1)])
        case .resume: return .object(["pause": .integer(0)])
        case .stop: return .object(["stop": .integer(1)])
        case .setNozzle(let c): return .object(["nozzleTempControl": .integer(c)])
        case .setBed(let c): return .object(["bedTempControl": .object(["num": .integer(0), "val": .integer(c)])])
        case .light(let on): return .object(["lightSw": .integer(on ? 1 : 0)])
        case .speed: throw IOError("Not available on Creality printers from this app")
        case .home, .move: return .object(["gcodeCmd": .string(motionGcode(command) ?? "")])
        }
    }

    public static func objectKey(_ displayName: String, _ fileMd5Hex: String) -> String {
        "model/slice/" + md5(Data("\(displayName):\(fileMd5Hex)".utf8)).hex(upper: true) + ".gcode.gz"
    }

    /// Aliyun OSS header signature: base64(HMAC-SHA1(secret, canonical string)).
    public static func ossSignature(_ secret: String, _ toSign: String) -> String {
        hmacSHA1(key: Data(secret.utf8), message: Data(toSign.utf8)).base64EncodedString()
    }

    /// 0 idle, 1 printing, 2 finished, 3 failed, 4 stopped, 5 paused.
    public static func state(_ s: Int) -> PrinterState {
        switch s {
        case 1: return .printing
        case 2: return .finished
        case 3, 4: return .failed
        case 5: return .paused
        case 0: return .idle
        default: return .unknown
        }
    }

    /// Timeseries reply: {key: [{ts, value}]} (possibly in the result envelope) → {key: value}.
    public static func parseTelemetry(_ reply: JSON) -> JSON {
        guard let map = reply.objectValue else { return .object([:]) }
        var out = [String: JSON]()
        for (k, v) in map {
            switch v {
            case .array(let a):
                if let value = a.first?.el("value") { out[k] = value }
            case .object:
                continue
            default:
                out[k] = v
            }
        }
        return .object(out)
    }
}
