import XCTest
@testable import UnifiedCore

final class FilamentFilesTests: XCTestCase {
    func testBambuAmsAndExternalSpool() {
        let print = json(#"""
        {"ams":{"tray_now":"1","ams":[{"id":"0","tray":[
            {"id":"0","tray_type":"PLA","tray_color":"FF0000FF","remain":80},
            {"id":"1","tray_type":"PETG","tray_color":"00FF00FF","remain":-1},
            {"id":"2"}]}]},
           "vt_tray":{"id":"254","tray_type":"TPU","tray_color":"000000FF"}}
        """#)
        let slots = BambuReport.filament(print)
        XCTAssertEqual(slots.map(\.label), ["A1", "A2", "A3", "Ext"])
        XCTAssertEqual(slots[0].color, "#FF0000")
        XCTAssertEqual(slots[0].remainPercent, 80)
        XCTAssertNil(slots[1].remainPercent)
        XCTAssertTrue(slots[1].active)
        XCTAssertTrue(slots[2].empty)
        XCTAssertFalse(slots[3].active)
        XCTAssertNil(BambuReport.bambuColor("FFFFFF00"))
    }

    func testElegooCanvas() {
        let ci = json(#"""
        {"active_canvas_id":0,"active_tray_id":2,"canvas_list":[{"canvas_id":0,"connected":1,"tray_list":[
            {"tray_id":0,"filament_type":"PLA","filament_color":"#ffffff"},
            {"tray_id":2,"filament_type":"PETG","filament_color":"112233"}]}]}
        """#)
        let slots = ElegooStatus.canvas(ci)
        XCTAssertEqual(slots.map(\.label), ["1", "3"])
        XCTAssertEqual(slots[0].color, "#FFFFFF")
        XCTAssertEqual(slots[1].color, "#112233")
        XCTAssertTrue(slots[1].active)
    }

    func testMotion() throws {
        XCTAssertEqual(motionGcode(.home), "G28")
        XCTAssertEqual(motionGcode(.move(.z, -0.1)), "G91\nG1 Z-0.1 F600\nG90")
        XCTAssertEqual(motionGcode(.move(.x, 10)), "G91\nG1 X10 F3000\nG90")
        let (method, params) = try elegooRequest(.move(.y, 1))
        XCTAssertEqual(method, 1027)
        XCTAssertEqual(params.str("axes"), "y")
        XCTAssertEqual(params.int("distance"), 1)
        XCTAssertEqual(BambuCommands.payload(.home, seq: "1").obj("print").str("command"), "gcode_line")
    }

    func testMoonrakerHistory() {
        let jobs = MoonrakerSource.parseHistory(json(#"""
        {"result":{"jobs":[{"filename":"a/b.gcode","status":"completed","start_time":1700000000.5,"print_duration":3600.2},
            {"filename":"c.gcode","status":"cancelled","start_time":1700000100}]}}
        """#))
        XCTAssertEqual(jobs[0].name, "b.gcode")
        XCTAssertEqual(jobs[0].state, .finished)
        XCTAssertEqual(jobs[0].startedAt?.ms, 1_700_000_000_500)
        XCTAssertEqual(jobs[0].durationSeconds, 3600)
        XCTAssertEqual(jobs[1].note, "Cancelled")
    }

    func testBambuTasks() {
        let list = BambuCloudSource.parseTasks(json(#"""
        {"hits":[{"title":"Benchy","status":2,"startTime":"2026-11-01T10:00:00Z","costTime":1800,"deviceId":"S1"},
            {"title":"Other printer","status":2,"deviceId":"S2"}]}
        """#), deviceId: "S1")
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].state, .finished)
        XCTAssertEqual(list[0].durationSeconds, 1800)
        XCTAssertEqual(list[0].startedAt, Date(timeIntervalSince1970: 1_793_527_200))
    }
}
