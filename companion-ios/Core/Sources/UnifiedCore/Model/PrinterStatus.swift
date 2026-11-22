import Foundation

public enum PrinterState: String, Codable, CaseIterable, Sendable {
    case offline = "OFFLINE"
    case idle = "IDLE"
    case preparing = "PREPARING"
    case printing = "PRINTING"
    case paused = "PAUSED"
    case finished = "FINISHED"
    case failed = "FAILED"
    case unknown = "UNKNOWN"

    public var label: String {
        switch self {
        case .offline: return "Offline"
        case .idle: return "Idle"
        case .preparing: return "Preparing"
        case .printing: return "Printing"
        case .paused: return "Paused"
        case .finished: return "Finished"
        case .failed: return "Failed"
        case .unknown: return "Unknown"
        }
    }

    public var active: Bool { self == .preparing || self == .printing || self == .paused }

    /// Known to be between prints, so it takes moves and new prints. Never true for `unknown` or
    /// `offline`: a printer whose state isn't known may be printing. Sources map states they don't
    /// recognise to `unknown`, and a print that is still winding down or waiting for the user to an
    /// active state, so `failed` only means "stopped".
    public var ready: Bool { self == .idle || self == .finished || self == .failed }
}

public struct Temperature: Equatable, Sendable {
    public var current: Double
    public var target: Double?

    public init(_ current: Double, target: Double? = nil) {
        self.current = current
        self.target = target
    }
}

/// One filament slot. `label` is what the maker's app shows ("A1", "Ext"), `color` is "#RRGGBB"
/// or nil when unknown, `remainPercent` is nil when the printer does not measure it.
public struct FilamentSlot: Equatable, Sendable, Hashable {
    public var label: String
    public var type: String
    public var color: String?
    public var remainPercent: Int?
    public var active: Bool
    /// Empty slot: no spool loaded.
    public var empty: Bool

    public init(label: String, type: String, color: String? = nil, remainPercent: Int? = nil, active: Bool = false, empty: Bool = false) {
        self.label = label
        self.type = type
        self.color = color
        self.remainPercent = remainPercent
        self.active = active
        self.empty = empty
    }
}

/// A file stored on the printer (or its host), which can be printed again.
public struct PrinterFile: Equatable, Sendable, Hashable {
    /// What the printer needs to print it, e.g. "folder/part.gcode".
    public var path: String
    public var name: String
    public var sizeBytes: Int64?
    public var modifiedAt: Date?

    public init(path: String, name: String? = nil, sizeBytes: Int64? = nil, modifiedAt: Date? = nil) {
        self.path = path
        self.name = name ?? String(path.split(separator: "/", omittingEmptySubsequences: false).last ?? Substring(path))
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }
}

/// One finished, failed or cancelled print from the printer's history.
public struct PastPrint: Equatable, Sendable, Hashable {
    public var name: String
    public var state: PrinterState
    public var startedAt: Date?
    public var durationSeconds: Int64?
    /// Shown instead of the state when the service has its own word for it.
    public var note: String?

    public init(name: String, state: PrinterState, startedAt: Date? = nil, durationSeconds: Int64? = nil, note: String? = nil) {
        self.name = name
        self.state = state
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.note = note
    }
}

/// One printer's last known state, as shown in the app.
public struct PrinterStatus: Equatable, Sendable, Identifiable {
    public var accountId: String
    public var deviceId: String
    public var name: String
    public var model: String
    public var brand: Brand
    /// Where the data comes from, e.g. "Bambu Cloud" or "LAN".
    public var via: String
    public var state: PrinterState
    /// Finer stage reported by the printer, e.g. "Heating bed".
    public var stage: String?
    public var progress: Int?
    public var remainingSeconds: Int64?
    public var layer: Int?
    public var totalLayers: Int?
    public var file: String?
    public var nozzle: Temperature?
    public var bed: Temperature?
    public var chamber: Temperature?
    /// Printer-side alert, e.g. an error code.
    public var alert: String?
    /// Chamber light, where the printer reports it.
    public var light: Bool?
    /// Bambu speed level 1...4.
    public var speedLevel: Int?
    /// Loaded filament: AMS / Canvas slots and the external spool, where the printer reports them.
    public var filament: [FilamentSlot]
    public var updatedAt: Date

    public init(
        accountId: String, deviceId: String, name: String, model: String = "", brand: Brand, via: String, state: PrinterState,
        stage: String? = nil, progress: Int? = nil, remainingSeconds: Int64? = nil, layer: Int? = nil, totalLayers: Int? = nil,
        file: String? = nil, nozzle: Temperature? = nil, bed: Temperature? = nil, chamber: Temperature? = nil, alert: String? = nil,
        light: Bool? = nil, speedLevel: Int? = nil, filament: [FilamentSlot] = [], updatedAt: Date = Date()
    ) {
        self.accountId = accountId
        self.deviceId = deviceId
        self.name = name
        self.model = model
        self.brand = brand
        self.via = via
        self.state = state
        self.stage = stage
        self.progress = progress
        self.remainingSeconds = remainingSeconds
        self.layer = layer
        self.totalLayers = totalLayers
        self.file = file
        self.nozzle = nozzle
        self.bed = bed
        self.chamber = chamber
        self.alert = alert
        self.light = light
        self.speedLevel = speedLevel
        self.filament = filament
        self.updatedAt = updatedAt
    }

    public var key: String { "\(accountId)/\(deviceId)" }
    public var id: String { key }
}

extension Date {
    /// From epoch milliseconds.
    public init(ms: Int64) { self.init(timeIntervalSince1970: TimeInterval(ms) / 1000) }
    public var ms: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}
