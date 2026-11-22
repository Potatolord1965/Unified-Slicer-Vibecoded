import Foundation

/// A Bambu printer in LAN mode: MQTT over TLS on port 8883, user "bblp", password = the access
/// code from the printer's screen. The printer's certificate must be Bambu Lab's and name `serial`.
public final class BambuLanSource: PrinterSource, Controllable, CameraCapable, @unchecked Sendable {
    private static let via = "LAN"

    public let printer: LanPrinter
    private let serial: String
    private let report = Locked<(JSON, Date)?>(nil)
    private let commands = BambuCommands()
    private let link: MQTTLink

    public init(_ printer: LanPrinter) {
        self.printer = printer
        let serial = printer.serial.trimmingCharacters(in: .whitespacesAndNewlines)
        self.serial = serial
        let report = self.report
        let commands = self.commands
        link = MQTTLink(
            host: bareHost(printer.host), port: 8883, tls: .bambu(serial: serial),
            username: "bblp", password: printer.secret, topics: ["device/\(serial)/report"],
            onConnected: { $0.publish("device/\(serial)/request", bambuPushAll) },
            onMessage: { _, payload in
                let message = JSON.parse(payload)
                commands.onReport(message)
                if let p = message.obj("print"), p.str("command") != "gcode_line" {
                    report.with { $0 = (JSON.merged($0?.0, p), Date()) }
                }
            }
        )
    }

    public var account: Account { .lan(printer) }

    private func plain(_ state: PrinterState) -> PrinterStatus {
        PrinterStatus(accountId: printer.id, deviceId: serial, name: printer.label, model: "", brand: .bambu, via: Self.via, state: state)
    }

    public func refresh() async throws -> [PrinterStatus] {
        do {
            if !link.isConnected {
                try await link.ensureConnected()
                try await awaitCondition(timeout: 6) { self.report.current != nil }
            }
        } catch let e as AuthError {
            throw e
        } catch let e as CertificateError {
            // A device that fails the certificate check isn't this printer being off: say why.
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return [plain(.offline)]
        }
        guard let r = report.current else { return [plain(.unknown)] }
        return [BambuReport.toStatus(accountId: printer.id, deviceId: serial, name: printer.label, model: "", via: Self.via, print: r.0, updatedAt: r.1)]
    }

    public func control(deviceId: String, command: PrinterCommand) async throws {
        try await link.ensureConnected()
        try await commands.send(link, serial: serial, command: command)
    }

    /// X1 printers report an RTSP address (or "disable"); the others stream JPEG on port 6000.
    public func camera(deviceId: String) async throws -> CameraFeed {
        let host = bareHost(printer.host)
        let rtsp = report.current?.0.obj("ipcam").str("rtsp_url")
        guard let url = rtsp else { return .bambuJpeg(host: host, accessCode: printer.secret, serial: serial) }
        if url.hasPrefix("rtsp") {
            return .bambuRtsp(url: "rtsp://bblp:\(formEncode(printer.secret))@\(host):322/streaming/live/1", serial: serial)
        }
        throw IOError("Turn on LAN Only Liveview on the printer's screen to watch the camera")
    }

    public func close() { link.close() }
}
