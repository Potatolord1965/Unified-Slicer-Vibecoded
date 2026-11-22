import Foundation

/// Commands on a Bambu printer's MQTT request topic, shared by cloud and LAN mode. Printers answer
/// on the report topic with the same sequence_id; firmware with "authorization control" refuses
/// unsigned commands there unless Developer Mode is on.
public final class BambuCommands: @unchecked Sendable {
    private let nextSeq = Locked(20000)
    private let replies = Locked([String: JSON]())
    private let waiting = Locked(Set<String>())

    public init() {}

    static let groups = ["print", "system"]

    /// Feed every report message here; completes the matching `send`.
    public func onReport(_ message: JSON?) {
        for group in Self.groups {
            guard let body = message.obj(group), let seq = body.str("sequence_id") else { continue }
            if waiting.current.contains(seq) { replies.with { $0[seq] = body } }
        }
    }

    public func send(_ link: MQTTLink, serial: String, command: PrinterCommand) async throws {
        guard link.isConnected else { throw IOError("Not connected to the printer") }
        let seq = String(nextSeq.with { n -> Int in n += 1; return n })
        waiting.with { _ = $0.insert(seq) }
        defer {
            waiting.with { _ = $0.remove(seq) }
            replies.with { $0[seq] = nil }
        }
        try await link.send("device/\(serial)/request", Self.payload(command, seq: seq).serialized)
        // Older firmware doesn't answer every command, so silence isn't a refusal, but it isn't
        // success either: say so, so a move isn't simply sent again.
        guard let reply = try await poll(timeout: 6, every: 0.1, { self.replies.current[seq] }) else {
            throw IOError("Sent, but the printer didn't confirm it. Check its status before sending it again.")
        }
        if let why = Self.rejection(reply) { throw IOError(why) }
    }

    public static func payload(_ command: PrinterCommand, seq: String) -> JSON {
        func print(_ name: String, _ param: String) -> JSON {
            .object(["print": .object(["sequence_id": .string(seq), "command": .string(name), "param": .string(param)])])
        }
        switch command {
        case .pause: return print("pause", "")
        case .resume: return print("resume", "")
        case .stop: return print("stop", "")
        case .setNozzle(let c): return print("gcode_line", "M104 S\(c)\n")
        case .setBed(let c): return print("gcode_line", "M140 S\(c)\n")
        case .speed(let level): return print("print_speed", String(level.rawValue))
        case .home, .move: return print("gcode_line", (motionGcode(command) ?? "") + "\n")
        case .light(let on):
            return .object(["system": .object([
                "sequence_id": .string(seq), "command": .string("ledctrl"), "led_node": .string("chamber_light"),
                "led_mode": .string(on ? "on" : "off"),
                "led_on_time": .integer(500), "led_off_time": .integer(500), "loop_times": .integer(0), "interval_time": .integer(0),
            ])])
        }
    }

    /// Why the printer refused, or nil when `reply` reports success.
    public static func rejection(_ reply: JSON) -> String? {
        let result = reply.str("result")?.lowercased()
        let code = reply.long("err_code") ?? 0
        if code == 0 && (result == nil || result == "success" || result == "ok") { return nil }
        let reason = reply.str("reason").flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        // 84033543 (0x05024007): the command was not signed by a Bambu app.
        if code == 84_033_543 || reason?.range(of: "verif", options: .caseInsensitive) != nil {
            return "The printer only accepts this from Bambu's own apps. Turn on Developer Mode on the printer (LAN only) to allow it."
        }
        if let r = reason { return "The printer refused the command: \(r)" }
        return "The printer refused the command" + (code != 0 ? " (error \(code))" : "")
    }
}
