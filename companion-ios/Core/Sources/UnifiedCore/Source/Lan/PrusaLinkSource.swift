import Foundation

/// Prusa printers through PrusaLink's v1 API.
public final class PrusaLinkSource: HTTPPrinterSource, PrintCapable, Controllable, CameraCapable, FileBrowsable, @unchecked Sendable {
    override var via: String { "LAN · PrusaLink" }

    override init(_ printer: LanPrinter, _ ctx: SourceContext) { super.init(printer, ctx) }

    override func read() async throws -> PrinterStatus {
        let status = try await get("/api/v1/status")
        var file: JSON?
        if status.obj("job") != nil { file = (try? await get("/api/v1/job"))?.obj("file") }
        return parse(status, file)
    }

    public func sendPrint(deviceId: String, job: PrintJob, progress: @escaping SendProgress) async throws {
        progress(0, "Uploading to the printer…")
        let size = max(fileSize(job.file), 1)
        let storage = await self.storage()
        let path = "/api/v1/files/\(storage)/" + formEncode(job.name)
        _ = try await ctx.http.fetchText(
            try request(path, method: "PUT", headers: [
                "Print-After-Upload": "?1", "Overwrite": "?1", "Content-Type": "application/octet-stream",
            ], body: .file(job.file), isUpload: true),
            onSent: { sent in progress(Int(sent * 100 / size), nil) }
        )
        progress(100, "Print started")
    }

    public func control(deviceId: String, command: PrinterCommand) async throws {
        guard let id = try await get("/api/v1/status").obj("job").int("id") else { throw IOError("The printer has no print job") }
        let json = ["Content-Type": "application/json; charset=utf-8"]
        let req: HTTPRequest
        switch command {
        case .pause: req = try request("/api/v1/job/\(id)/pause", method: "PUT", headers: json, body: .data(Data()))
        case .resume: req = try request("/api/v1/job/\(id)/resume", method: "PUT", headers: json, body: .data(Data()))
        case .stop: req = try request("/api/v1/job/\(id)", method: "DELETE")
        default: throw IOError("Not available on PrusaLink from this app")
        }
        _ = try await ctx.http.fetchText(req)
    }

    public func camera(deviceId: String) async throws -> CameraFeed {
        .http(url: resolve("/api/v1/cameras/snap"), headers: keyHeaders)
    }

    /// The printer's own storage: "usb" on MK4/XL/MINI, "local" on PrusaLink for the MK3.
    private func storage() async -> String {
        let list = (try? await get("/api/v1/storage"))?.arr("storage_list") ?? []
        let path = list.first { $0.bool("available") != false && $0.bool("read_only") != true }?.str("path")
        let trimmed = path?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.flatMap { $0.isEmpty ? nil : $0 } ?? "usb"
    }

    public func files(deviceId: String) async throws -> [PrinterFile] {
        let storage = await self.storage()
        let children = try await get("/api/v1/files/\(storage)").arr("children") ?? []
        return children.filter { $0.str("type") == "PRINT_FILE" }.compactMap { f -> PrinterFile? in
            guard let name = f.str("name") else { return nil }
            return PrinterFile(path: "\(storage)/\(name)", name: f.str("display_name") ?? name, sizeBytes: f.long("size"),
                               modifiedAt: f.long("m_timestamp").map { Date(timeIntervalSince1970: TimeInterval($0)) })
        }.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    public func printFile(deviceId: String, file: PrinterFile) async throws {
        _ = try await ctx.http.fetchText(try request(
            "/api/v1/files/" + encodePath(file.path), method: "POST", headers: ["Content-Type": "application/json; charset=utf-8"], body: .data(Data())
        ))
    }

    func parse(_ s: JSON, _ file: JSON?) -> PrinterStatus {
        let p = s.obj("printer")
        let raw = p.str("state")?.uppercased()
        let state: PrinterState
        switch raw {
        case "IDLE", "READY": state = .idle
        case "BUSY": state = .preparing
        case "PRINTING": state = .printing
        case "PAUSED": state = .paused
        case "FINISHED": state = .finished
        case "STOPPED", "ERROR": state = .failed
        case "ATTENTION": state = .paused
        default: state = .unknown
        }
        let job = s.obj("job")
        let printing = state.active || state == .finished
        var out = status(state)
        out.stage = raw == "ATTENTION" ? "Needs attention" : nil
        out.progress = printing ? job.int("progress") : nil
        out.remainingSeconds = job.long("time_remaining").flatMap { state.active && $0 > 0 ? $0 : nil }
        out.file = printing ? (file.str("display_name") ?? file.str("name")) : nil
        out.nozzle = p.num("temp_nozzle").map { Temperature($0, target: p.num("target_nozzle").flatMap { $0 > 0 ? $0 : nil }) }
        out.bed = p.num("temp_bed").map { Temperature($0, target: p.num("target_bed").flatMap { $0 > 0 ? $0 : nil }) }
        return out
    }
}
