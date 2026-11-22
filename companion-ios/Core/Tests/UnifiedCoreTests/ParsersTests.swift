import XCTest
@testable import UnifiedCore

final class ParsersTests: XCTestCase {
    let ctx = SourceContext(http: noHTTP())

    func testBambuReport() {
        let p = json(#"{"gcode_state":"RUNNING","mc_percent":42,"mc_remaining_time":75,"layer_num":10,"total_layer_num":200,"subtask_name":"Benchy","nozzle_temper":219.5,"nozzle_target_temper":220,"bed_temper":"60","bed_target_temper":60,"print_error":0}"#)
        let s = BambuReport.toStatus(accountId: "a", deviceId: "SN", name: "X1C", model: "X1 Carbon", via: "Bambu Cloud", print: p, updatedAt: Date(ms: 1))
        XCTAssertEqual(s.state, .printing)
        XCTAssertEqual(s.progress, 42)
        XCTAssertEqual(s.remainingSeconds, 4500)
        XCTAssertEqual(s.file, "Benchy")
        XCTAssertEqual(s.bed?.current, 60)
        XCTAssertNil(s.alert)
    }

    func testBambuErrorCode() {
        let s = BambuReport.toStatus(accountId: "a", deviceId: "SN", name: "n", model: "", via: "LAN", print: json(#"{"gcode_state":"FAILED","print_error":50364420}"#), updatedAt: Date())
        XCTAssertEqual(s.alert, "Error 03008004")
    }

    func testBambuDeltaMerge() {
        let full = json(#"{"gcode_state":"RUNNING","mc_percent":10,"nozzle_temper":200}"#)
        let merged = JSON.merged(full, json(#"{"mc_percent":11}"#))
        let s = BambuReport.toStatus(accountId: "a", deviceId: "SN", name: "P1S", model: "", via: "LAN", print: merged, updatedAt: Date(ms: 1))
        XCTAssertEqual(s.progress, 11)
        XCTAssertEqual(s.nozzle?.current, 200)
    }

    func testElegooCloudReport() {
        let data = json(#"""
        {"machine_status":[{"reportLinkKey":"status","reportValue":"2","updateTime":1700000000000},
        {"reportLinkKey":"sub_status","reportValue":"1405","updateTime":1700000000500},{"reportLinkKey":"progress","reportValue":"3"}],
        "print_status":[{"reportLinkKey":"filename","reportValue":"\"cube.gcode\""},{"reportLinkKey":"remaining_time_sec","reportValue":"600"}],
        "extruder":[{"reportLinkKey":"temperature","reportValue":"150.2"},{"reportLinkKey":"target","reportValue":"220"}]}
        """#)
        let (report, updated) = ElegooCloudSource.parseReport(data)
        XCTAssertEqual(updated, 1_700_000_000_500)
        let s = ElegooStatus.toStatus(accountId: "a", deviceId: "SN", name: "Potato Printer", model: "CC2", via: "Elegoo Cloud", status: report, updatedAt: Date(ms: updated))
        XCTAssertEqual(s.state, .preparing)
        XCTAssertEqual(s.stage, "Heating bed")
        XCTAssertEqual(s.file, "cube.gcode")
        XCTAssertEqual(s.remainingSeconds, 600)
        XCTAssertEqual(s.nozzle?.target, 220)
    }

    func testElegooStates() {
        XCTAssertEqual(ElegooStatus.state(1, 0), .idle)
        XCTAssertEqual(ElegooStatus.state(1, 2077), .finished)
        XCTAssertEqual(ElegooStatus.state(2, 2502), .paused)
        XCTAssertEqual(ElegooStatus.state(2, 2075), .printing)
        XCTAssertEqual(ElegooStatus.state(2, 2503), .printing)
        XCTAssertEqual(ElegooStatus.state(2, 2504), .failed)
        // A code this app doesn't know may be a busy printer: never idle.
        XCTAssertEqual(ElegooStatus.state(7, 0), .unknown)
        XCTAssertEqual(ElegooStatus.state(nil, nil), .unknown)
    }

    func testOnlyKnownIdleStatesTakeMovesAndPrints() {
        XCTAssertEqual(Set(PrinterState.allCases.filter(\.ready)), [.idle, .finished, .failed])
    }

    func testElegooLoginReport() {
        let a = ElegooCloudSource.accountFromLogin(json(#"{"accessToken":"t","refreshToken":"r","userId":123,"nickname":"Nate"}"#), id: "id")
        XCTAssertEqual(a?.userId, "123")
        XCTAssertEqual(a?.label, "Nate")
        XCTAssertNil(ElegooCloudSource.accountFromLogin(json(#"{"nickname":"x"}"#), id: "id"))
        XCTAssertTrue(ElegooCloudSource.isElegooPage("https://www.nexprint.com/account/slicer-login"))
        XCTAssertFalse(ElegooCloudSource.isElegooPage("https://nexprint.com.evil.io/"))
        XCTAssertFalse(ElegooCloudSource.isElegooPage("http://www.nexprint.com/"))
    }

    func testElegooLoginURL() {
        let url = ElegooCloudSource.loginURL(deviceId: "abc", dark: true)
        XCTAssertEqual(url, "https://www.nexprint.com/account/slicer-login?language=en&region=US&theme=dark&deviceId=abc")
    }

    func testCrealityTelemetry() {
        let t = CrealityCloudSource.parseTelemetry(json(#"{"nozzleTemp":[{"ts":1,"value":"210"}],"state":[{"ts":1,"value":1}],"x":{"a":1}}"#))
        XCTAssertEqual(Set(t.objectValue?.keys.map { $0 } ?? []), ["nozzleTemp", "state"])
        XCTAssertEqual(CrealityCloudSource.state(5), .paused)
        XCTAssertEqual(CrealityCloudSource.state(0), .idle)
        XCTAssertEqual(CrealityCloudSource.state(9), .unknown)
    }

    func testEigerStates() {
        XCTAssertEqual(EigerSource.state("Printing", "heating"), .preparing)
        XCTAssertEqual(EigerSource.state("Out of Material", nil), .paused)
        XCTAssertEqual(EigerSource.state("Ready", nil), .idle)
        XCTAssertEqual(EigerSource.state("Disabled", nil), .offline)
        XCTAssertEqual(EigerSource.state("Some new state", nil), .unknown)
    }

    func testMoonraker() {
        let src = MoonrakerSource(LanPrinter(id: "l", label: "Voron", kind: .moonraker, host: "10.0.0.2"), ctx)
        let s = src.parse(json(#"{"print_stats":{"state":"printing","filename":"a.gcode","print_duration":600,"info":{"current_layer":5,"total_layer":50}},"virtual_sdcard":{"progress":0.25},"extruder":{"temperature":240.1,"target":240},"heater_bed":{"temperature":100,"target":0}}"#))
        XCTAssertEqual(s.state, .printing)
        XCTAssertEqual(s.progress, 25)
        XCTAssertEqual(s.remainingSeconds, 1800)
        XCTAssertNotNil(s.bed)
        XCTAssertNil(s.bed?.target)
    }

    func testOctoPrint() {
        let src = OctoPrintSource(LanPrinter(id: "l", label: "Ender", kind: .octoprint, host: "octopi.local", secret: "key"), ctx)
        let s = src.parse(
            json(#"{"state":{"flags":{"operational":true,"printing":true}},"temperature":{"tool0":{"actual":200,"target":205},"bed":{"actual":60,"target":60}}}"#),
            json(#"{"job":{"file":{"name":"x.gcode"}},"progress":{"completion":50.5,"printTimeLeft":100}}"#)
        )
        XCTAssertEqual(s.state, .printing)
        XCTAssertEqual(s.progress, 50)
        XCTAssertEqual(s.file, "x.gcode")
    }

    func testPrusaLink() {
        let src = PrusaLinkSource(LanPrinter(id: "l", label: "MK4", kind: .prusaLink, host: "10.0.0.3", secret: "key"), ctx)
        let s = src.parse(
            json(#"{"printer":{"state":"PRINTING","temp_nozzle":215,"target_nozzle":215,"temp_bed":60,"target_bed":60},"job":{"id":1,"progress":12,"time_remaining":3600}}"#),
            json(#"{"display_name":"part.bgcode"}"#)
        )
        XCTAssertEqual(s.state, .printing)
        XCTAssertEqual(s.file, "part.bgcode")
        XCTAssertEqual(s.remainingSeconds, 3600)
    }

    func testEmptyReportIsUnknown() {
        let s = ElegooStatus.toStatus(accountId: "a", deviceId: "SN", name: "n", model: "m", via: "v", status: .object([:]), updatedAt: Date())
        XCTAssertEqual(s.state, .unknown)
    }
}
