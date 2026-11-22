import Foundation

/// Elegoo Cloud (matrix.elegoo.com), as used by ElegooSlicer and Unified Slicer: bound printers
/// from device/list, last reported status from device/report-data/list.
public final class ElegooCloudSource: PrinterSource, PrintCapable, Controllable, @unchecked Sendable {
    static let via = "Elegoo Cloud"
    public static let loginURL = "https://www.nexprint.com/account/slicer-login"
    /// Elegoo's sign-in page only issues device-API tokens to a client that presents itself as ElegooSlicer.
    public static let loginUserAgent = "ElegooSlicer/1.5.3.5 (dark) Mozilla/5.0 (Windows NT 10.0; Win64; x64)"

    private let ctx: SourceContext
    private let current: Locked<ElegooAccount>
    private let renewing = Locked<Task<Void, Error>?>(nil)

    public init(_ account: ElegooAccount, _ ctx: SourceContext) {
        current = Locked(account)
        self.ctx = ctx
    }

    public var account: Account { .elegoo(current.current) }

    public func refresh() async throws -> [PrinterStatus] {
        let list = try await call("GET", "/api/v1/device-management-server/device/list")
        let devices = list.el("data")?.arrayValue ?? []
        let a = current.current
        return try await withThrowingTaskGroup(of: (Int, PrinterStatus).self) { group in
            for (index, d) in devices.enumerated() {
                guard let serial = d.str("serialNo") else { continue }
                let model = d.str("pcode") ?? ""
                let name = d.str("deviceName") ?? (model.isEmpty ? serial : model)
                let online = d.bool("online") ?? d.int("onlineStatus").map { $0 == 1 }
                group.addTask {
                    if online == false {
                        return (index, PrinterStatus(accountId: a.id, deviceId: serial, name: name, model: model, brand: .elegoo, via: Self.via, state: .offline))
                    }
                    let (report, updated) = try await self.report(serial)
                    let at = updated > 0 ? Date(ms: updated) : Date()
                    return (index, ElegooStatus.toStatus(accountId: a.id, deviceId: serial, name: name, model: model, via: Self.via, status: report, updatedAt: at))
                }
            }
            var out = [(Int, PrinterStatus)]()
            for try await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// The cloud's last report as {group: {field: value}}, plus its newest update time.
    private func report(_ serial: String) async throws -> (JSON, Int64) {
        let reply = try await call("GET", "/api/v1/device-management-server/device/report-data/list?deviceCode=" + formEncode(serial))
        return Self.parseReport(reply.el("data"))
    }

    /// Cloud print as ElegooSlicer does it: upload to Elegoo's storage, tell the printer over
    /// messaging to download it (1057, progress 6006), then start it (1020).
    public func sendPrint(deviceId: String, job: PrintJob, progress: @escaping SendProgress) async throws {
        guard ctx.rtm != nil else { throw IOError("Elegoo cloud printing is not available on this device") }
        let serial = deviceId
        let name = hasExtension(job.name, ".gcode", ".3mf") ? job.name : job.name + ".gcode"
        progress(0, "Checking the printer…")
        if try await report(serial).0.obj("machine_status").int("status") == 2 {
            throw IOError("The printer is busy with another print")
        }

        let digest = try md5(file: job.file)
        let hex = digest.hex()
        let ext = "." + (name.split(separator: ".").last.map(String.init) ?? "").lowercased()
        let a = current.current
        let serverName = String(a.userId.suffix(6)) + "_" + String(serial.suffix(6)) + "_" + hex + ext
        let before = await fileCreateTime(serial, name)

        progress(0, "Uploading to the Elegoo cloud…")
        let md5Base64 = digest.base64EncodedString()
        let slot = try await call("GET", "/api/v1/device-management-server/oss/biz-entrypoint?filename=" + formEncode(serverName) +
            "&bucketAlias=iot-private&module=gcode&fileMd5=" + formEncode(md5Base64)).obj("data")
        guard let entry = slot.str("entrypoint"), let url = slot.str("accessUrl") else {
            throw IOError("Elegoo did not provide an upload slot")
        }
        let size = max(fileSize(job.file), 1)
        // Cloudflare in front of the bucket rejects requests without a client identity (fetchText adds ours).
        _ = try await ctx.http.fetchText(
            try HTTPRequest(entry, method: "PUT", headers: ["Content-MD5": md5Base64, "Content-Type": "application/octet-stream"], body: .file(job.file), isUpload: true),
            onSent: { sent in progress(Int(sent * 50 / size), nil) }
        )

        progress(50, "Connecting to the printer…")
        let channel = try await openChannel(serial)
        defer { channel.close() }
        let task: JSON = .object(["taskID": .string(serial)])
        _ = try? await channel.request(ElegooPrinterChannel.mCancelDownload, task, timeout: 5) // nothing to cancel is fine
        try await pause(1)
        channel.download = nil
        progress(50, "The printer is downloading the file…")
        try await channel.request(ElegooPrinterChannel.mDownloadFile, .object([
            "filename": .string(name), "url": .string(url), "md5": .string(hex), "taskID": .string(serial),
        ]), timeout: 15)
        do {
            try await awaitDownload(channel, serial, name, before, progress)
        } catch is CancellationError {
            _ = await Task.detached {
                try? await channel.request(ElegooPrinterChannel.mCancelDownload, task, timeout: 5, needReply: false)
            }.value
            throw CancellationError()
        }

        progress(100, "Starting the print…")
        func start(_ force: Bool) -> JSON {
            .object([
                "storage_media": .string("local"),
                "filename": .string(name),
                "config": .object([
                    "delay_video": .bool(false), "printer_check": .bool(true), "print_layout": .string("A"),
                    "bedlevel_force": .bool(force), "slot_map": .array([]),
                ]),
            ])
        }
        do {
            try await channel.request(ElegooPrinterChannel.mStartPrint, start(false), timeout: 10)
        } catch let e as ElegooPrinterError where e.code == 1026 {
            // No bed mesh saved yet: level first.
            try await channel.request(ElegooPrinterChannel.mStartPrint, start(true), timeout: 10)
        }
        progress(100, "Print started")
    }

    /// A messaging session with one printer; the caller closes it.
    private func openChannel(_ serial: String) async throws -> ElegooPrinterChannel {
        guard let rtm = ctx.rtm else { throw IOError("Elegoo cloud control is not available on this device") }
        let token = try await call("GET", "/api/v1/device-management-server/device/list/agora-token?source=slicer").obj("data").obj("agoraToken")
        guard let rtmUser = token.str("rtmUserId"), let rtmToken = token.str("rtmToken") else {
            throw IOError("Elegoo did not return a messaging token for this account")
        }
        return try await ElegooPrinterChannel.open(rtm: rtm, agoraUserId: token.str("userId") ?? "", rtmUserId: rtmUser, rtmToken: rtmToken, serial: serial)
    }

    public func control(deviceId: String, command: PrinterCommand) async throws {
        let (method, params) = try elegooRequest(command)
        let channel = try await openChannel(deviceId)
        defer { channel.close() }
        try await channel.request(method, params, timeout: 10)
    }

    private func awaitDownload(_ channel: ElegooPrinterChannel, _ serial: String, _ name: String, _ before: String?, _ progress: SendProgress) async throws {
        var lastPct = -1
        var lastChange = Date()
        while true {
            try await pause(0.5)
            if let d = channel.download {
                let pct = d.int("progress") ?? 0
                if pct != lastPct {
                    lastPct = pct
                    lastChange = Date()
                    progress(50 + pct / 2, nil)
                }
                switch d.int("status") {
                case 1: return
                case 2: throw IOError("The printer cancelled the download")
                case 3: throw IOError("The printer failed to download the file")
                default: break
                }
            }
            if Date().timeIntervalSince(lastChange) > 60 {
                // No progress for a minute: the file may have landed anyway.
                let now = await fileCreateTime(serial, name)
                if let n = now, n != before { return }
                throw IOError("The printer reported no download progress for 60 seconds")
            }
        }
    }

    /// createTime of a file on the printer as the cloud knows it, or nil.
    private func fileCreateTime(_ serial: String, _ name: String) async -> String? {
        let reply = try? await call("GET", "/api/v1/device-management-server/local-file/filename?serialNo=" + formEncode(serial) + "&filename=" + formEncode(name))
        return reply?.obj("data")?["createTime"]?.serialized
    }

    private func call(_ method: String, _ path: String, _ body: JSON? = nil) async throws -> JSON {
        try await ensureFreshToken()
        do {
            return try await request(method, path, body, current.current.accessToken)
        } catch is AuthError {
            try await renew()
            return try await request(method, path, body, current.current.accessToken)
        }
    }

    private func request(_ method: String, _ path: String, _ body: JSON?, _ token: String?) async throws -> JSON {
        var headers = ["Accept": "application/json"]
        if let t = token { headers["Authorization"] = "Bearer \(t)" }
        let url = Self.apiBase(current.current.region) + path
        let req: HTTPRequest
        if let b = body {
            req = try .json(url, method: method, b, headers: headers)
        } else {
            req = try HTTPRequest(url, method: method, headers: headers)
        }
        let reply = try await ctx.http.fetchJSON(req)
        // The API answers HTTP 200 with its own code.
        let code = reply.int("code") ?? -1
        switch code {
        case 0: return reply
        case 401, 403: throw AuthError("Elegoo sign-in expired")
        default:
            let text = "Elegoo API: code \(code) \(reply.str("msg") ?? reply.str("message") ?? "")"
            throw IOError(text.trimmingCharacters(in: .whitespaces))
        }
    }

    private func ensureFreshToken() async throws {
        let a = current.current
        var exp = a.accessExpireMs
        if (1...9_999_999_999).contains(exp) { exp *= 1000 } // seconds, not ms
        if exp > 1_000_000_000_000 && exp - 60_000 < Date().ms && !a.refreshToken.isEmpty { try await renew() }
    }

    /// Renews the token; callers that arrive while a renewal runs wait for it.
    private func renew() async throws {
        let task: Task<Void, Error> = renewing.with { r in
            if let t = r { return t }
            let t = Task { [self] in
                defer { renewing.set(nil) }
                try await renewNow()
            }
            r = t
            return t
        }
        try await task.value
    }

    private func renewNow() async throws {
        let a = current.current
        if a.refreshToken.isEmpty { throw AuthError("Elegoo sign-in expired") }
        let d: JSON?
        do {
            d = try await request("POST", "/api/v1/account-center-server/account-auth/token/refresh",
                                  .object(["refreshToken": .string(a.refreshToken), "clientId": .string("Slicer")]), a.accessToken).el("data")
        } catch is HTTPError {
            throw AuthError("Elegoo sign-in expired")
        } catch is AuthError {
            throw AuthError("Elegoo sign-in expired")
        } catch let e as IOError where e.message.hasPrefix("Elegoo API") {
            throw AuthError("Elegoo sign-in expired")
        }
        guard let token = d.str("accessToken") else { throw AuthError("Elegoo sign-in expired") }
        var renewed = a
        renewed.accessToken = token
        renewed.refreshToken = d.str("refreshToken") ?? a.refreshToken
        renewed.accessExpireMs = d.long("expiresTime") ?? 0
        current.set(renewed)
        ctx.onAccountUpdated(.elegoo(renewed))
    }

    public func close() {}

    public static func apiBase(_ region: String) -> String { region == "CN" ? "https://matrix.elegoo.com.cn" : "https://matrix.elegoo.com" }

    public static func loginURL(deviceId: String, dark: Bool) -> String {
        var c = URLComponents(string: loginURL)!
        c.queryItems = [
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "region", value: "US"),
            URLQueryItem(name: "theme", value: dark ? "dark" : "light"),
            URLQueryItem(name: "deviceId", value: deviceId),
        ]
        return c.url?.absoluteString ?? loginURL
    }

    /// Only Elegoo's own pages may hand the app an account.
    public static func isElegooPage(_ url: String?) -> Bool {
        guard let s = url, let u = URL(string: s), u.scheme?.lowercased() == "https", let host = u.host?.lowercased() else { return false }
        return ["nexprint.com", "nexprint.cn", "elegoo.com", "elegoo.com.cn"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Builds an account from the sign-in page's report.userInfo params, or nil if it carries none.
    public static func accountFromLogin(_ params: JSON?, id: String) -> ElegooAccount? {
        func pick(_ keys: String...) -> String? {
            for k in keys { if let v = params.str(k) { return v } }
            return nil
        }
        guard let token = pick("accessToken", "token"), let user = pick("userId", "accountId") else { return nil }
        return ElegooAccount(
            id: id, label: pick("nickname", "email") ?? "Elegoo account", accessToken: token,
            refreshToken: pick("refreshToken") ?? "", accessExpireMs: params.long("accessTokenExpireTime") ?? 0, userId: user
        )
    }

    /// report-data/list's data: {group: [{reportLinkKey, reportValue, updateTime}]}.
    public static func parseReport(_ data: JSON?) -> (JSON, Int64) {
        var newest: Int64 = 0
        var groups = [String: JSON]()
        for (group, items) in data?.objectValue ?? [:] {
            guard let list = items.arrayValue else { continue }
            var fields = [String: JSON]()
            for item in list {
                guard let key = item.str("reportLinkKey") else { continue }
                newest = max(newest, item.long("updateTime") ?? 0)
                let raw = item.el("reportValue")
                // Values come as JSON-encoded strings ("2", "\"name.gcode\"", "{...}").
                if case .string(let text)? = raw {
                    fields[key] = JSON.parse(text) ?? .string(text)
                } else {
                    fields[key] = raw ?? .null
                }
            }
            groups[group] = .object(fields)
        }
        return (.object(groups), newest)
    }
}
