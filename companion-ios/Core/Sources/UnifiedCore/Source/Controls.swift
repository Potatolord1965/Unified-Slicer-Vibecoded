import Foundation

/// What a printer can be told to do from the app.
public enum Control: String, CaseIterable, Sendable {
    case pause, resume, stop, nozzleTemp, bedTemp, light, speed, move
}

/// Bambu's print speed levels; `rawValue` is the value the printer reports and accepts.
public enum SpeedLevel: Int, CaseIterable, Sendable {
    case silent = 1, standard = 2, sport = 3, ludicrous = 4

    public var label: String {
        switch self {
        case .silent: return "Silent"
        case .standard: return "Standard"
        case .sport: return "Sport"
        case .ludicrous: return "Ludicrous"
        }
    }

    public static func of(_ level: Int?) -> SpeedLevel? { level.flatMap(SpeedLevel.init(rawValue:)) }
}

public enum Axis: String, Sendable {
    case x, y, z
}

public enum PrinterCommand: Equatable, Sendable {
    case pause
    case resume
    case stop
    /// 0 turns the heater off.
    case setNozzle(Int)
    case setBed(Int)
    case light(Bool)
    case speed(SpeedLevel)
    /// Homes all axes.
    case home
    /// Moves one axis by `mm`, relative to where it is.
    case move(Axis, Double)

    public var control: Control {
        switch self {
        case .pause: return .pause
        case .resume: return .resume
        case .stop: return .stop
        case .setNozzle: return .nozzleTemp
        case .setBed: return .bedTemp
        case .light: return .light
        case .speed: return .speed
        case .home, .move: return .move
        }
    }
}

/// A source whose printers take commands.
public protocol Controllable {
    /// Sends `command` to the printer `deviceId`. Throws with a readable message when it is refused.
    func control(deviceId: String, command: PrinterCommand) async throws
}

private let jobControls: Set<Control> = [.pause, .resume, .stop]
private let jobAndTemps: Set<Control> = jobControls.union([.nozzleTemp, .bedTemp])
private let fullControls: Set<Control> = jobAndTemps.union([.move])

/// The controls printers of `account` offer in this app.
public func controlsFor(_ account: Account) -> Set<Control> {
    switch account {
    case .bambu: return fullControls.union([.light, .speed])
    case .elegoo: return fullControls
    case .creality: return fullControls.union([.light])
    case .markforged: return []
    case .lan(let p):
        switch p.kind {
        case .bambu: return fullControls.union([.light, .speed])
        case .elegooCC2, .moonraker, .octoprint: return fullControls
        case .prusaLink: return jobControls
        }
    }
}

/// G-code for a move or home, for printers that take raw G-code. Nil for other commands.
public func motionGcode(_ command: PrinterCommand) -> String? {
    switch command {
    case .home:
        return "G28"
    // Relative move at a modest feed rate, then back to absolute; Z moves slower.
    case .move(let axis, let mm):
        let feed = axis == .z ? 600 : 3000
        return "G91\nG1 \(axis.rawValue.uppercased())\(formatMM(mm)) F\(feed)\nG90"
    default:
        return nil
    }
}

func formatMM(_ mm: Double) -> String {
    if mm == mm.rounded(.towardZero), abs(mm) < 1e15 { return String(Int64(mm)) }
    return "\(mm)"
}

/// A source whose printers keep files that can be listed and printed again.
public protocol FileBrowsable {
    func files(deviceId: String) async throws -> [PrinterFile]
    /// Starts printing `file`, already on the printer.
    func printFile(deviceId: String, file: PrinterFile) async throws
}

/// A source that keeps a history of past prints.
public protocol HistoryCapable {
    /// Newest first.
    func history(deviceId: String) async throws -> [PastPrint]
}

/// Whether printers of `account` can list their stored files in this app.
public func canBrowseFiles(_ account: Account) -> Bool {
    guard case .lan(let p) = account else { return false }
    return [.moonraker, .octoprint, .prusaLink].contains(p.kind)
}

/// Whether this app can read `account`'s print history.
public func hasHistory(_ account: Account) -> Bool {
    switch account {
    case .bambu: return true
    case .lan(let p): return p.kind == .moonraker
    default: return false
    }
}
