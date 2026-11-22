import Foundation

let bambuPushAll = #"{"pushing":{"sequence_id":"0","command":"pushall","version":1,"push_target":1}}"#

/// Bambu Cloud: the account's bound printers from the REST API, live status from Bambu's MQTT
/// broker (user "u_<uid>", password = access token, topic device/<serial>/report).
public final class BambuCloudSource: PrinterSource, Controllable, HistoryCapable, @unchecked Sendable {
    private struct Device {
        let id: String
        let name: String
        let model: String
        let online: Bool
        let printStatus: String?
    }

    private struct State {
        var devices: [Device] = []
        var devicesAt = Date.distantPast
        var link: MQTTLink?
        var linkSerials: Set<String> = []
    }

    private static let via = "Bambu Cloud"
    private static let deviceListTTL: TimeInterval = 60

    private let ctx: SourceContext
    private let current: Locked<BambuAccount>
    private let state = Locked(State())
    private let commands = BambuCommands()
    private let reports = Locked([String: (JSON, Date)]())

    public init(_ account: BambuAccount, _ ctx: SourceContext) {
        current = Locked(account)
        self.ctx = ctx
    }

    public var account: Account { .bambu(current.current) }

    public func refresh() async throws -> [PrinterStatus] {
        if Date().timeIntervalSince(state.current.devicesAt) > Self.deviceListTTL {
            let devices = try await withRenewal { try await self.fetchDevices() }
            state.with {
                $0.devices = devices
                $0.devicesAt = Date()
            }
        }
        try await withRenewal { try await self.connectLink() }
        let a = current.current
        let known = reports.current
        return state.current.devices.map { d in
            if !d.online {
                return PrinterStatus(accountId: a.id, deviceId: d.id, name: d.name, model: d.model, brand: .bambu, via: Self.via, state: .offline)
            }
            if let r = known[d.id] {
                return BambuReport.toStatus(accountId: a.id, deviceId: d.id, name: d.name, model: d.model, via: Self.via, print: r.0, updatedAt: r.1)
            }
            // Until the printer's first report: the device list only tells a running task apart.
            return PrinterStatus(
                accountId: a.id, deviceId: d.id, name: d.name, model: d.model, brand: .bambu, via: Self.via,
                state: d.printStatus == "ACTIVE" ? .printing : .unknown
            )
        }
    }

    private func connectLink() async throws {
        let a = current.current
        let link: MQTTLink? = state.with { s in
            let serials = Set(s.devices.map(\.id))
            if s.link == nil || serials != s.linkSerials {
                s.link?.close()
                s.linkSerials = serials
                s.link = serials.isEmpty ? nil : MQTTLink(
                    host: BambuAuth.mqttHost(a.region), port: 8883, tls: .system,
                    username: "u_\(a.uid)", password: a.accessToken,
                    topics: serials.sorted().map { "device/\($0)/report" },
                    onConnected: { l in serials.forEach { l.publish("device/\($0)/request", bambuPushAll) } },
                    onMessage: { [weak self] topic, payload in self?.onMessage(topic, payload) }
                )
            }
            return s.link
        }
        guard let l = link, !l.isConnected else { return }
        try await l.ensureConnected()
        let online = state.current.devices.filter(\.online).map(\.id)
        try await awaitCondition(timeout: 6) {
            let r = self.reports.current
            return online.allSatisfy { r[$0] != nil }
        }
    }

    private func onMessage(_ topic: String, _ payload: Data) {
        var rest = Substring(topic)
        if rest.hasPrefix("device/") { rest = rest.dropFirst(7) }
        let serial = String(rest.prefix { $0 != "/" })
        let message = JSON.parse(payload)
        commands.onReport(message)
        guard let print = message.obj("print"), print.str("command") != "gcode_line" else { return }
        reports.with { $0[serial] = (JSON.merged($0[serial]?.0, print), Date()) }
    }

    private func fetchDevices() async throws -> [Device] {
        let a = current.current
        let reply = try await ctx.http.fetchJSON(
            try HTTPRequest(BambuAuth.apiBase(a.region) + "/v1/iot-service/api/user/bind", headers: ["Authorization": "Bearer \(a.accessToken)"])
        )
        return (reply.arr("devices") ?? []).compactMap { d in
            guard let id = d.str("dev_id") else { return nil }
            return Device(
                id: id, name: d.str("name") ?? id,
                model: d.str("dev_product_name") ?? d.str("dev_model_name") ?? "",
                online: d.bool("online") ?? true, printStatus: d.str("print_status")
            )
        }
    }

    /// Runs `block`; on a rejected token renews it once and retries.
    private func withRenewal<T>(_ block: () async throws -> T) async throws -> T {
        do {
            return try await block()
        } catch is AuthError {
            let renewed = try await BambuAuth(ctx.http).refresh(current.current)
            current.set(renewed)
            ctx.onAccountUpdated(.bambu(renewed))
            let old: MQTTLink? = state.with { s in
                let l = s.link
                s.link = nil
                return l
            }
            old?.close()
            return try await block()
        }
    }

    public func control(deviceId: String, command: PrinterCommand) async throws {
        try await withRenewal { try await self.connectLink() }
        guard let link = state.current.link else { throw IOError("Not connected to Bambu's cloud") }
        try await commands.send(link, serial: deviceId, command: command)
    }

    /// Bambu's cloud task list, as Bambu Handy's history.
    public func history(deviceId: String) async throws -> [PastPrint] {
        try await withRenewal {
            let a = self.current.current
            let reply = try await self.ctx.http.fetchJSON(try HTTPRequest(
                BambuAuth.apiBase(a.region) + "/v1/user-service/my/tasks?limit=30&deviceId=" + formEncode(deviceId),
                headers: ["Authorization": "Bearer \(a.accessToken)"]
            ))
            return Self.parseTasks(reply, deviceId: deviceId)
        }
    }

    public func close() {
        let old: MQTTLink? = state.with { s in
            let l = s.link
            s.link = nil
            return l
        }
        old?.close()
    }

    /// hits[]: {title, designTitle, status, startTime (ISO), costTime (s), deviceId}. Status 2 finished, 3 failed, 1 running.
    public static func parseTasks(_ reply: JSON, deviceId: String) -> [PastPrint] {
        (reply.arr("hits") ?? [])
            .filter { t in
                let d = t.str("deviceId")
                return d == nil || d == deviceId
            }
            .compactMap { t in
                let title = t.str("title").flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                guard let name = title ?? t.str("designTitle") else { return nil }
                let state: PrinterState
                switch t.int("status") {
                case 1: state = .printing
                case 2: state = .finished
                case 3: state = .failed
                default: state = .unknown
                }
                return PastPrint(
                    name: name, state: state, startedAt: parseISODate(t.str("startTime")),
                    durationSeconds: t.long("costTime").flatMap { $0 > 0 ? $0 : nil }
                )
            }
    }
}
