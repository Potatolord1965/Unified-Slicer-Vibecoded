import Foundation

/// Klipper through Moonraker's HTTP API.
public final class MoonrakerSource: HTTPPrinterSource, PrintCapable, Controllable, CameraCapable, FileBrowsable, HistoryCapable, @unchecked Sendable {
    override var via: String { "LAN · Moonraker" }

    override init(_ printer: LanPrinter, _ ctx: SourceContext) { super.init(printer, ctx) }

    override func read() async throws -> PrinterStatus {
        let reply: JSON
        do {
            reply = try await get("/printer/objects/query?print_stats&virtual_sdcard&display_status&extruder&heater_bed")
        } catch let e as HTTPError where e.code == 503 || e.code == 400 {
            // Moonraker is up but Klipper is not ready (shutdown, firmware restart, MCU error).
            var s = status(.failed)
            s.alert = "Klipper not ready"
            return s
        }
        return parse(reply.obj("result").obj("status"))
    }

    public func sendPrint(deviceId: String, job: PrintJob, progress: @escaping SendProgress) async throws {
        progress(0, "Uploading to the printer…")
        try await uploadMultipart("/server/files/upload", fields: [("root", "gcodes"), ("print", "true")], job: job, progress: progress)
        progress(100, "Print started")
    }

    public func control(deviceId: String, command: PrinterCommand) async throws {
        switch command {
        case .pause: try await post("/printer/print/pause")
        case .resume: try await post("/printer/print/resume")
        case .stop: try await post("/printer/print/cancel")
        case .setNozzle(let c): try await gcode("M104 S\(c)")
        case .setBed(let c): try await gcode("M140 S\(c)")
        case .home, .move: try await gcode(motionGcode(command) ?? "")
        case .light, .speed: throw IOError("Not available on Klipper printers from this app")
        }
    }

    private func gcode(_ script: String) async throws {
        try await post("/printer/gcode/script?script=" + formEncode(script))
    }

    /// The first webcam configured in Moonraker, else the usual mjpg-streamer address.
    public func camera(deviceId: String) async throws -> CameraFeed {
        let cams = (try? await get("/server/webcams/list"))?.obj("result").arr("webcams")
        let cam = cams?.first { $0.bool("enabled") != false }
        let snapshot = cam.str("snapshot_url").flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        return .http(url: resolve(snapshot ?? "/webcam/?action=snapshot"), headers: [:])
    }

    public func files(deviceId: String) async throws -> [PrinterFile] {
        let list = try await get("/server/files/list?root=gcodes").arr("result") ?? []
        return list.compactMap { f -> PrinterFile? in
            guard let path = f.str("path") else { return nil }
            return PrinterFile(path: path, sizeBytes: f.long("size"), modifiedAt: f.num("modified").map { Date(timeIntervalSince1970: $0) })
        }.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    public func printFile(deviceId: String, file: PrinterFile) async throws {
        try await post("/printer/print/start?filename=" + encodePath(file.path))
    }

    public func history(deviceId: String) async throws -> [PastPrint] {
        Self.parseHistory(try await get("/server/history/list?limit=30&order=desc"))
    }

    public static func parseHistory(_ reply: JSON) -> [PastPrint] {
        (reply.obj("result").arr("jobs") ?? []).compactMap { j in
            guard let name = j.str("filename") else { return nil }
            let status = j.str("status")
            let state: PrinterState
            switch status {
            case "completed": state = .finished
            case "in_progress": state = .printing
            case "cancelled", "error", "klippy_shutdown", "klippy_disconnect", "server_exit", "interrupted": state = .failed
            default: state = .unknown
            }
            let note: String?
            switch status {
            case "cancelled": note = "Cancelled"
            case "klippy_shutdown", "klippy_disconnect": note = "Klipper stopped"
            default: note = nil
            }
            return PastPrint(
                name: String(name.split(separator: "/", omittingEmptySubsequences: false).last ?? Substring(name)),
                state: state,
                startedAt: j.num("start_time").map { Date(timeIntervalSince1970: $0) },
                durationSeconds: j.num("print_duration").flatMap(JSON.toInt64).flatMap { $0 > 0 ? $0 : nil },
                note: note
            )
        }
    }

    func parse(_ s: JSON?) -> PrinterStatus {
        let ps = s.obj("print_stats")
        let state: PrinterState
        switch ps.str("state") {
        case "standby": state = .idle
        case "printing": state = .printing
        case "paused": state = .paused
        case "complete": state = .finished
        case "cancelled", "error": state = .failed
        default: state = .unknown
        }
        let printing = state.active || state == .finished
        let progress = s.obj("virtual_sdcard").num("progress") ?? s.obj("display_status").num("progress")
        let duration = ps.num("print_duration")
        var remaining: Int64?
        if let p = progress, let d = duration, p > 0.01 { remaining = JSON.toInt64(d / p - d) }
        var out = status(state)
        out.progress = printing ? progress.flatMap { JSON.toInt64($0 * 100) }.map { Int(clamping: $0) } : nil
        out.remainingSeconds = remaining.flatMap { state.active && $0 > 0 ? $0 : nil }
        out.layer = printing ? ps.obj("info").int("current_layer") : nil
        out.totalLayers = ps.obj("info").int("total_layer").flatMap { printing && $0 > 0 ? $0 : nil }
        out.file = printing ? ps.str("filename") : nil
        out.nozzle = groupTemp(s, "extruder")
        out.bed = groupTemp(s, "heater_bed")
        out.alert = state == .failed ? ps.str("message") : nil
        return out
    }
}
