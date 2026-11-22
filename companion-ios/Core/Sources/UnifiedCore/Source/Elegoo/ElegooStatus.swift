import Foundation

/// The Centauri Carbon 2 status object (method 6000/1002 on the printer, report-data in the
/// cloud): machine_status, print_status, extruder, heater_bed, ztemperature_sensor, ...
public enum ElegooStatus {
    static let subStatus: [Int: String] = [
        1081: "Downloading file", 1082: "Downloading file", 1086: "Downloading file",
        1041: "Heating nozzle", 1045: "Heating nozzle", 1096: "Heating nozzle",
        1405: "Heating bed", 1906: "Heating bed", 2801: "Homing", 2802: "Homing",
        2901: "Auto bed leveling", 2902: "Auto bed leveling", 2501: "Pausing", 2502: "Paused",
        2505: "Paused", 2401: "Resuming", 2402: "Resuming", 2075: "Printing",
        2077: "Print finished", 2503: "Stopping", 2504: "Stopped",
    ]
    static let preparing: Set<Int> = [1041, 1045, 1096, 1405, 1906, 2801, 2802, 2901, 2902, 1081, 1082, 1086]

    public static func state(_ status: Int?, _ sub: Int?) -> PrinterState {
        switch status {
        case 2:
            switch sub {
            case 2501, 2502, 2505: return .paused
            case 2077: return .finished
            // 2503 "Stopping" is still moving, so it counts as printing until 2504 "Stopped".
            case 2504: return .failed
            case let s? where preparing.contains(s): return .preparing
            default: return .printing
            }
        case 1: return sub == 2077 ? .finished : .idle
        case 0: return .preparing
        case 14: return .failed
        default: return .unknown
        }
    }

    /// Canvas (multi-colour unit) trays, as in elegoo-link's handleCanvasStatus: canvas_list[] with
    /// tray_list[] {tray_id, filament_type, filament_color, status}; active_canvas_id/active_tray_id.
    public static func canvas(_ ci: JSON?) -> [FilamentSlot] {
        guard let ci = ci else { return [] }
        let activeCanvas = ci.int("active_canvas_id")
        let activeTray = ci.int("active_tray_id")
        let list = ci.arr("canvas_list") ?? []
        let many = list.count > 1
        var out = [FilamentSlot]()
        for canvas in list {
            let id = canvas.int("canvas_id") ?? 0
            if canvas.int("connected") == 0 { continue }
            for tray in canvas.arr("tray_list") ?? [] {
                guard let trayId = tray.int("tray_id") else { continue }
                let type = tray.str("filament_type") ?? ""
                let color = tray.str("filament_color").map { c in c.hasPrefix("#") ? c.uppercased() : "#" + c.uppercased() }
                out.append(FilamentSlot(
                    label: (many ? "\(id + 1)-" : "") + String(trayId + 1),
                    type: type.isEmpty ? "Empty" : type,
                    color: color.flatMap { $0.count == 7 ? $0 : nil },
                    active: id == activeCanvas && trayId == activeTray,
                    empty: type.isEmpty
                ))
            }
        }
        return out
    }

    public static func toStatus(
        accountId: String, deviceId: String, name: String, model: String, via: String, status s: JSON, updatedAt: Date
    ) -> PrinterStatus {
        let ms = s.obj("machine_status")
        let ps = s.obj("print_status")
        let sub = ms.int("sub_status")
        let state = state(ms.int("status"), sub)
        let printing = state.active || state == .finished
        func temp(_ group: String) -> Temperature? {
            guard let g = s.obj(group), let t = g.num("temperature") else { return nil }
            return Temperature(t, target: g.num("target").flatMap { $0 > 0 ? $0 : nil })
        }
        let alert = ms.int("exception_status").flatMap { $0 != 0 ? $0 : nil }
        return PrinterStatus(
            accountId: accountId, deviceId: deviceId, name: name, model: model, brand: .elegoo, via: via, state: state,
            stage: state.active ? sub.flatMap { subStatus[$0] } : nil,
            progress: printing ? ms.int("progress") : nil,
            remainingSeconds: ps.long("remaining_time_sec").flatMap { state.active && $0 > 0 ? $0 : nil },
            layer: printing ? ps.int("current_layer") : nil,
            totalLayers: ps.int("total_layer").flatMap { printing && $0 > 0 ? $0 : nil },
            file: printing ? ps.str("filename") : nil,
            nozzle: temp("extruder"),
            bed: temp("heater_bed"),
            chamber: temp("ztemperature_sensor"),
            alert: alert.map { "Alert \($0)" },
            filament: canvas(s.obj("canvas_info")),
            updatedAt: updatedAt
        )
    }
}
