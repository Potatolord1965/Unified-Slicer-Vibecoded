import Foundation

/// Markforged Eiger public API v3 (Basic auth with the organization's API keys). Eiger reports no temperatures.
public final class EigerSource: PrinterSource, @unchecked Sendable {
    static let api = "https://www.eiger.io/api/v3"

    public let markforged: MarkforgedAccount
    private let ctx: SourceContext
    private let auth: String

    public init(_ account: MarkforgedAccount, _ ctx: SourceContext) {
        markforged = account
        self.ctx = ctx
        auth = "Basic " + Data("\(account.accessKey):\(account.secretKey)".utf8).base64EncodedString()
    }

    public var account: Account { .markforged(markforged) }

    private func get(_ path: String) async throws -> JSON {
        try await ctx.http.fetchJSON(try HTTPRequest(Self.api + path, headers: ["Authorization": auth]))
    }

    public func refresh() async throws -> [PrinterStatus] {
        var list = [JSON]()
        for page in 1...20 {
            let res = try await get("/devices?page%5Bnumber%5D=\(page)&page%5Bsize%5D=100")
            list += res.arrayValue ?? res.arr("items") ?? []
            if res.bool("has_more_items") != true { break }
        }
        return try await withThrowingTaskGroup(of: (Int, PrinterStatus).self) { group in
            for (i, d) in list.enumerated() {
                guard let id = d.str("id") else { continue }
                // The list carries no active job; the device record does.
                group.addTask {
                    let detail = (try? await self.get("/devices/\(id)")) ?? d
                    return (i, self.toStatus(id, detail))
                }
            }
            var out = [(Int, PrinterStatus)]()
            for try await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    public func toStatus(_ id: String, _ d: JSON) -> PrinterStatus {
        let raw = d.str("state") ?? ""
        let job = d.obj("active_job")
        let state = Self.state(raw, job.str("printing_state"))
        let printing = state.active || state == .finished
        return PrinterStatus(
            accountId: markforged.id, deviceId: id, name: d.str("name") ?? id, model: d.str("device_type") ?? "",
            brand: .markforged, via: "Eiger", state: state,
            stage: !raw.isEmpty && state == .failed ? raw : nil,
            progress: printing ? job.int("progress") : nil,
            remainingSeconds: job.long("estimated_seconds_remaining").flatMap { state.active && $0 > 0 ? $0 : nil },
            layer: printing ? job.int("current_layer") : nil,
            totalLayers: job.int("layer_count").flatMap { printing && $0 > 0 ? $0 : nil },
            file: printing ? job.obj("build").str("title") : nil
        )
    }

    public func close() {}

    public static func state(_ state: String, _ printingState: String?) -> PrinterState {
        switch state.lowercased() {
        case "printing":
            return ["heating", "scanning", "calibrating"].contains(printingState?.lowercased() ?? "") ? .preparing : .printing
        case "print paused": return .paused
        case "print finished": return .finished
        // The print is held until someone clears the jam or loads material.
        case "material jam", "fiber jam", "out of material", "user action required": return .paused
        case "ready", "idle": return .idle
        case "offline", "disconnected", "disabled": return .offline
        default: return .unknown
        }
    }
}
