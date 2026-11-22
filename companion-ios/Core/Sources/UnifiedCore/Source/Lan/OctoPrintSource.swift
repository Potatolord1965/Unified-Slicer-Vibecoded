import Foundation

public final class OctoPrintSource: HTTPPrinterSource, PrintCapable, Controllable, CameraCapable, FileBrowsable, @unchecked Sendable {
    override var via: String { "LAN · OctoPrint" }

    override init(_ printer: LanPrinter, _ ctx: SourceContext) { super.init(printer, ctx) }

    override func read() async throws -> PrinterStatus {
        let printer: JSON
        do {
            printer = try await get("/api/printer")
        } catch let e as HTTPError where e.code == 409 {
            // 409: OctoPrint is running but not connected to the printer.
            var s = status(.offline)
            s.alert = "OctoPrint is not connected to the printer"
            return s
        }
        return parse(printer, try await get("/api/job"))
    }

    public func sendPrint(deviceId: String, job: PrintJob, progress: @escaping SendProgress) async throws {
        progress(0, "Uploading to OctoPrint…")
        try await uploadMultipart("/api/files/local", fields: [("select", "true"), ("print", "true")], job: job, progress: progress)
        progress(100, "Print started")
    }

    public func control(deviceId: String, command: PrinterCommand) async throws {
        switch command {
        case .pause: try await post("/api/job", #"{"command":"pause","action":"pause"}"#)
        case .resume: try await post("/api/job", #"{"command":"pause","action":"resume"}"#)
        case .stop: try await post("/api/job", #"{"command":"cancel"}"#)
        case .setNozzle(let c): try await post("/api/printer/tool", #"{"command":"target","targets":{"tool0":\#(c)}}"#)
        case .setBed(let c): try await post("/api/printer/bed", #"{"command":"target","target":\#(c)}"#)
        case .home: try await post("/api/printer/printhead", #"{"command":"home","axes":["x","y","z"]}"#)
        case .move(let axis, let mm):
            try await post("/api/printer/printhead", JSON.object(["command": .string("jog"), axis.rawValue: .decimal(mm)]).serialized)
        case .light, .speed: throw IOError("Not available on OctoPrint from this app")
        }
    }

    public func camera(deviceId: String) async throws -> CameraFeed { .http(url: resolve("/webcam/?action=snapshot"), headers: [:]) }

    public func files(deviceId: String) async throws -> [PrinterFile] {
        var out = [PrinterFile]()
        func walk(_ list: [JSON]) {
            for f in list {
                switch f.str("type") {
                case "folder": walk(f.arr("children") ?? [])
                case "machinecode":
                    if let path = f.str("path") {
                        out.append(PrinterFile(path: path, name: f.str("name") ?? path, sizeBytes: f.long("size"),
                                               modifiedAt: f.long("date").map { Date(timeIntervalSince1970: TimeInterval($0)) }))
                    }
                default: break
                }
            }
        }
        walk(try await get("/api/files/local?recursive=true").arr("files") ?? [])
        return out.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    public func printFile(deviceId: String, file: PrinterFile) async throws {
        try await post("/api/files/local/" + encodePath(file.path), #"{"command":"select","print":true}"#)
    }

    func parse(_ printer: JSON, _ job: JSON) -> PrinterStatus {
        let flags = printer.obj("state").obj("flags")
        let state: PrinterState
        if flags.bool("error") == true || flags.bool("closedOrError") == true {
            state = .failed
        } else if flags.bool("paused") == true || flags.bool("pausing") == true {
            state = .paused
        } else if flags.bool("printing") == true || flags.bool("cancelling") == true {
            state = .printing
        } else if flags.bool("ready") == true || flags.bool("operational") == true {
            state = .idle
        } else {
            state = .unknown
        }
        let progress = job.obj("progress")
        let temps = printer.obj("temperature")
        var out = status(state)
        out.progress = state.active ? progress.int("completion") : nil
        out.remainingSeconds = progress.long("printTimeLeft").flatMap { state.active && $0 > 0 ? $0 : nil }
        out.file = state.active ? job.obj("job").obj("file").str("name") : nil
        out.nozzle = groupTemp(temps, "tool0", cur: "actual", target: "target")
        out.bed = groupTemp(temps, "bed", cur: "actual", target: "target")
        out.alert = printer.obj("state").str("error")
        return out
    }
}
