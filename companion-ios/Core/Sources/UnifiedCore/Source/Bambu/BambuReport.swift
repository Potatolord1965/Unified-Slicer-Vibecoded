import Foundation

/// Bambu printers' MQTT "print" report (push_status), shared by cloud and LAN mode.
public enum BambuReport {
    public static func state(_ gcodeState: String?) -> PrinterState {
        switch gcodeState?.uppercased() {
        case "IDLE": return .idle
        case "PREPARE", "SLICING", "INIT": return .preparing
        case "RUNNING": return .printing
        case "PAUSE": return .paused
        case "FINISH": return .finished
        case "FAILED": return .failed
        default: return .unknown
        }
    }

    // stg_cur: the printer's current calibration / preparation step.
    static let stages: [Int: String] = [
        1: "Auto bed leveling", 2: "Heating bed", 3: "Vibration compensation",
        4: "Changing filament", 7: "Heating nozzle", 8: "Calibrating extrusion",
        9: "Scanning bed surface", 10: "Inspecting first layer", 13: "Homing",
        14: "Cleaning nozzle", 16: "Paused by user", 17: "Front cover fell off",
        19: "Calibrating extrusion flow", 20: "Nozzle temperature malfunction",
        21: "Bed temperature malfunction", 22: "Unloading filament", 24: "Loading filament",
        25: "Calibrating motor noise", 29: "Cooling chamber", 35: "Paused: nozzle clog",
    ]

    /// AMS units ("ams" → "ams"[] → "tray"[]) and the external spool ("vt_tray"). "tray_now" is the
    /// loaded tray: unit * 4 + slot, 254 the external spool, 255 none. AMS HT units have ids from 128.
    public static func filament(_ print: JSON) -> [FilamentSlot] {
        let ams = print.obj("ams")
        let now = ams.str("tray_now").flatMap { Int($0) }
        var slots = [FilamentSlot]()
        for unit in ams.arr("ams") ?? [] {
            guard let id = unit.str("id").flatMap({ Int($0) }) else { continue }
            let ht = id >= 128
            let letter = ht ? "HT\(id - 127)" : String(UnicodeScalar(UInt8(clamping: 65 + id)))
            for tray in unit.arr("tray") ?? [] {
                guard let slot = tray.str("id").flatMap({ Int($0) }) else { continue }
                let type = tray.str("tray_type") ?? ""
                let remain = tray.int("remain")
                slots.append(FilamentSlot(
                    label: ht ? letter : "\(letter)\(slot + 1)",
                    type: type.isEmpty ? "Empty" : type,
                    color: bambuColor(tray.str("tray_color")),
                    remainPercent: remain.flatMap { (0...100).contains($0) ? $0 : nil },
                    active: (!ht && now == id * 4 + slot) || (ht && now == id),
                    empty: type.isEmpty
                ))
            }
        }
        if let vt = print.obj("vt_tray") {
            let type = vt.str("tray_type") ?? ""
            if !type.isEmpty || slots.isEmpty {
                slots.append(FilamentSlot(
                    label: "Ext", type: type.isEmpty ? "Empty" : type, color: bambuColor(vt.str("tray_color")),
                    active: now == 254, empty: type.isEmpty
                ))
            }
        }
        return slots
    }

    /// "RRGGBBAA" → "#RRGGBB"; nil for missing or fully transparent.
    public static func bambuColor(_ raw: String?) -> String? {
        guard var hex = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        let first6 = hex.prefix(6)
        guard hex.count >= 6, first6.allSatisfy({ $0.isHexDigit }) else { return nil }
        if hex.count == 8 && hex.hasSuffix("00") { return nil }
        return "#" + first6.uppercased()
    }

    public static func toStatus(
        accountId: String, deviceId: String, name: String, model: String, via: String, print: JSON, updatedAt: Date
    ) -> PrinterStatus {
        let state = state(print.str("gcode_state"))
        let printing = state.active || state == .finished
        let err = print.long("print_error") ?? 0
        func temp(_ cur: String, _ target: String?) -> Temperature? {
            print.num(cur).map { Temperature($0, target: target.flatMap { print.num($0) }) }
        }
        let light = print.arr("lights_report")?.first { $0.str("node") == "chamber_light" }?.str("mode").map { $0 != "off" }
        return PrinterStatus(
            accountId: accountId,
            deviceId: deviceId,
            name: name,
            model: model,
            brand: .bambu,
            via: via,
            state: state,
            stage: state.active ? print.int("stg_cur").flatMap { stages[$0] } : nil,
            progress: printing ? print.int("mc_percent") : nil,
            remainingSeconds: print.long("mc_remaining_time").map { $0 * 60 }.flatMap { state.active && $0 > 0 ? $0 : nil },
            layer: printing ? print.int("layer_num") : nil,
            totalLayers: print.int("total_layer_num").flatMap { printing && $0 > 0 ? $0 : nil },
            file: printing ? (print.str("subtask_name") ?? print.str("gcode_file")) : nil,
            nozzle: temp("nozzle_temper", "nozzle_target_temper"),
            bed: temp("bed_temper", "bed_target_temper"),
            chamber: print.num("chamber_temper").flatMap { $0 > 0 ? Temperature($0) : nil },
            alert: err != 0 ? String(format: "Error %08X", UInt32(truncatingIfNeeded: err)) : nil,
            light: light,
            speedLevel: state.active ? print.int("spd_lvl") : nil,
            filament: filament(print),
            updatedAt: updatedAt
        )
    }
}
