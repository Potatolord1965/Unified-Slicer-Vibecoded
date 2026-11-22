import Foundation

/// Elegoo Centauri Carbon 2 on the local network, as in elegoo-link and the desktop plug-in
/// elegoo_cc2_lan.py: serial from http://<ip>/system/info, then MQTT on port 1883 (user "elegoo",
/// password = access code), register, request the full status (1002) and merge 6000 pushes.
public final class ElegooLanSource: PrinterSource, PrintCapable, Controllable, @unchecked Sendable {
    static let via = "LAN"
    static let defaultAccessCode = "123456"
    static let mStatus = 1002
    static let mStart = 1020
    static let mStatusPush = 6000
    static let chunk: Int64 = 1 << 20
    static let model = "Centauri Carbon 2"

    public let printer: LanPrinter
    private let ctx: SourceContext
    private let host: String
    private let code: String
    private let clientId = "1_PC_" + String(Int.random(in: 1000..<10000))
    private var requestId: String { clientId + "_req" }

    private struct State {
        var serial: String
        var link: MQTTLink?
        var status: JSON?
        var statusAt = Date()
    }

    private let state: Locked<State>
    private let replies = Locked([Int: JSON]())
    private let waiting = Locked(Set<Int>())
    private let nextId = Locked(2000)

    public init(_ printer: LanPrinter, _ ctx: SourceContext) {
        self.printer = printer
        self.ctx = ctx
        host = bareHost(printer.host)
        code = printer.secret.isEmpty ? Self.defaultAccessCode : printer.secret
        state = Locked(State(serial: printer.serial))
    }

    public var account: Account { .lan(printer) }

    private var deviceId: String {
        let s = state.current.serial
        return s.isEmpty ? host : s
    }

    private func plain(_ s: PrinterState) -> PrinterStatus {
        PrinterStatus(accountId: printer.id, deviceId: deviceId, name: printer.label, model: Self.model, brand: .elegoo, via: Self.via, state: s)
    }

    public func refresh() async throws -> [PrinterStatus] {
        do {
            if state.current.serial.isEmpty {
                let serial = try await fetchSerial()
                state.with { $0.serial = serial }
            }
            let l: MQTTLink = state.with { s in
                if let l = s.link { return l }
                let l = createLink(serial: s.serial)
                s.link = l
                return l
            }
            if !l.isConnected {
                try await l.ensureConnected()
                try await awaitCondition(timeout: 8) { self.state.current.status != nil }
            }
        } catch let e as AuthError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return [plain(.offline)]
        }
        let s = state.current
        guard let status = s.status else { return [plain(.unknown)] }
        return [ElegooStatus.toStatus(accountId: printer.id, deviceId: deviceId, name: printer.label, model: Self.model, via: Self.via, status: status, updatedAt: s.statusAt)]
    }

    private func connectedLink() async throws -> MQTTLink {
        _ = try await refresh()
        guard let l = state.current.link, l.isConnected else { throw IOError("The printer is not reachable on this network") }
        return l
    }

    /// Upload in 1 MB chunks to http://<ip>/upload, then start it with request 1020.
    public func sendPrint(deviceId: String, job: PrintJob, progress: @escaping SendProgress) async throws {
        progress(0, "Connecting to the printer…")
        let l = try await connectedLink()
        if state.current.status.obj("machine_status").int("status") == 2 { throw IOError("The printer is busy with another print") }

        progress(0, "Uploading to the printer…")
        let size = fileSize(job.file)
        let digest = try md5(file: job.file).hex()
        let handle = try FileHandle(forReadingFrom: job.file)
        defer { try? handle.close() }
        var offset: Int64 = 0
        while offset < size {
            let len = min(Self.chunk, size - offset)
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: Int(len)) ?? Data()
            guard data.count == Int(len) else { throw IOError("\(job.name) is shorter than expected") }
            let text = try await ctx.http.fetchText(try HTTPRequest(
                "http://\(host)/upload", method: "PUT",
                headers: [
                    "Content-Range": "bytes \(offset)-\(offset + len - 1)/\(size)",
                    "X-File-Name": job.name,
                    "X-File-MD5": digest,
                    "X-Token": code,
                    "Content-Type": "application/octet-stream",
                ],
                body: .data(data), isUpload: true
            ))
            let reply = JSON.parse(text.isEmpty ? "{}" : text)
            let err = reply.int("error_code") ?? 0
            if err != 0 { throw IOError("The printer refused the upload (error \(err))") }
            offset += len
            progress(Int(offset * 100 / max(size, 1)), nil)
        }

        progress(100, "Starting the print…")
        let start: JSON = .object([
            "storage_media": .string("local"), "filename": .string(job.name),
            "config": .object(["delay_video": .bool(false), "printer_check": .bool(true), "print_layout": .string("A"), "slot_map": .array([])]),
        ])
        do {
            try await request(l, Self.mStart, start)
        } catch let e as ElegooPrinterError {
            throw IOError("The printer refused to start the print (error \(e.code))")
        }
        progress(100, "Print started")
    }

    public func control(deviceId: String, command: PrinterCommand) async throws {
        let (method, params) = try elegooRequest(command)
        let l = try await connectedLink()
        try await request(l, method, params)
    }

    /// One request on the printer's API topic; replies are matched by id.
    @discardableResult
    private func request(_ l: MQTTLink, _ method: Int, _ params: JSON) async throws -> JSON {
        let id = nextId.with { n -> Int in
            n += 1
            return n
        }
        waiting.with { _ = $0.insert(id) }
        defer {
            waiting.with { _ = $0.remove(id) }
            replies.with { $0[id] = nil }
        }
        let serial = state.current.serial
        let msg: JSON = .object(["id": .integer(id), "method": .integer(method), "params": params])
        try await l.send("elegoo/\(serial)/\(clientId)/api_request", msg.serialized)
        guard let reply = try await poll(timeout: 10, every: 0.1, { self.replies.current[id] }) else {
            throw IOError("The printer did not answer")
        }
        let err = reply.obj("result").int("error_code") ?? 0
        if err != 0 { throw ElegooPrinterError(code: err, method: method) }
        return reply
    }

    private func fetchSerial() async throws -> String {
        // The access code goes in a header. Elegoo's own slicer also puts it in the address, so
        // firmware that only reads it there gets a second try with it, instead of it always
        // travelling in a URL.
        func systemInfo(_ inAddress: Bool) async throws -> JSON? {
            let url = "http://\(host)/system/info" + (inAddress ? "?X-Token=" + formEncode(code) : "")
            do {
                return try await ctx.http.fetchJSON(try HTTPRequest(url, headers: ["X-Token": code]), authErrors: inAddress)
            } catch let e as HTTPError {
                if !inAddress && (e.code == 401 || e.code == 403) { return nil }
                throw IOError(e.message)
            }
        }
        var reply = try await systemInfo(false)
        if reply == nil || (reply.int("error_code") ?? 0) != 0 { reply = try await systemInfo(true) }
        let err = reply.int("error_code") ?? 0
        if err != 0 { throw AuthError("The printer rejected the access code (error \(err))") }
        guard let sn = reply.obj("system_info").str("sn") else { throw IOError("The printer did not report a serial number") }
        return sn
    }

    private func createLink(serial: String) -> MQTTLink {
        let base = "elegoo/\(serial)/"
        let cid = clientId
        let rid = requestId
        return MQTTLink(
            host: host, port: 1883, tls: .none, username: "elegoo", password: code,
            topics: [base + cid + "/api_response", base + "api_status", base + rid + "/register_response"],
            clientId: cid,
            onConnected: { l in l.publish(base + "api_register", #"{"client_id":"\#(cid)","request_id":"\#(rid)"}"#) },
            onMessage: { [weak self] topic, payload in self?.onMessage(topic, payload) }
        )
    }

    private func onMessage(_ topic: String, _ payload: Data) {
        guard let msg = JSON.parse(payload) else { return }
        let serial = state.current.serial
        if topic.hasSuffix("/register_response") {
            if msg.str("error") == "ok" {
                state.current.link?.publish("elegoo/\(serial)/\(clientId)/api_request", #"{"id":1,"method":\#(Self.mStatus),"params":{}}"#)
            }
            return
        }
        if topic.hasSuffix("/api_response"), let id = msg.int("id"), waiting.current.contains(id) {
            replies.with { $0[id] = msg }
            return
        }
        guard let result = msg.el("result"), result.objectValue != nil else { return }
        let method = msg.int("method")
        state.with { s in
            if method == Self.mStatusPush {
                s.status = JSON.merged(s.status, result)
            } else if topic.hasSuffix("/api_response") && (method == Self.mStatus || msg.int("id") == 1) {
                s.status = result
            } else {
                return
            }
            s.statusAt = Date()
        }
    }

    public func close() {
        let l: MQTTLink? = state.with { s in
            let old = s.link
            s.link = nil
            return old
        }
        l?.close()
    }
}
