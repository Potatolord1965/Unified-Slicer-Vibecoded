import XCTest
@testable import UnifiedCore

final class ControlTests: XCTestCase {
    func testBambuPayloads() {
        let pause = BambuCommands.payload(.pause, seq: "7").obj("print")
        XCTAssertEqual(pause.str("command"), "pause")
        XCTAssertEqual(pause.str("sequence_id"), "7")
        XCTAssertEqual(BambuCommands.payload(.setNozzle(215), seq: "1").obj("print").str("param"), "M104 S215\n")
        XCTAssertEqual(BambuCommands.payload(.speed(.sport), seq: "1").obj("print").str("param"), "3")
        let light = BambuCommands.payload(.light(false), seq: "1").obj("system")
        XCTAssertEqual(light.str("command"), "ledctrl")
        XCTAssertEqual(light.str("led_mode"), "off")
    }

    func testBambuRejections() {
        XCTAssertNil(BambuCommands.rejection(json(#"{"command":"pause","result":"success","reason":""}"#)))
        XCTAssertNil(BambuCommands.rejection(json(#"{"command":"pause"}"#)))
        XCTAssertTrue(BambuCommands.rejection(json(#"{"command":"gcode_line","result":"failed","err_code":84033543,"reason":"mqtt message verify failed"}"#))?.contains("Developer Mode") == true)
        XCTAssertTrue(BambuCommands.rejection(json(#"{"command":"stop","result":"fail","reason":"busy"}"#))?.hasSuffix("busy") == true)
    }

    func testBambuLightAndSpeed() {
        let report = json(#"{"gcode_state":"RUNNING","spd_lvl":2,"lights_report":[{"node":"chamber_light","mode":"on"}]}"#)
        let status = BambuReport.toStatus(accountId: "a", deviceId: "d", name: "n", model: "X1C", via: "LAN", print: report, updatedAt: Date())
        XCTAssertEqual(status.light, true)
        XCTAssertEqual(SpeedLevel.of(status.speedLevel), .standard)
    }

    func testElegooAndCrealityRequests() throws {
        XCTAssertEqual(try elegooRequest(.resume).0, ElegooPrinterChannel.mResumePrint)
        let (method, params) = try elegooRequest(.setBed(60))
        XCTAssertEqual(method, 1028)
        XCTAssertEqual(params.int("heater_bed"), 60)
        XCTAssertEqual(try CrealityCloudSource.controlParams(.resume).int("pause"), 0)
        XCTAssertEqual(try CrealityCloudSource.controlParams(.setBed(60)).obj("bedTempControl").int("val"), 60)
        XCTAssertThrowsError(try elegooRequest(.light(true)))
    }

    func testControlsPerPrinterKind() {
        XCTAssertTrue(controlsFor(.lan(LanPrinter(id: "1", label: "x", kind: .bambu, host: "10.0.0.2"))).contains(.speed))
        XCTAssertFalse(controlsFor(.lan(LanPrinter(id: "1", label: "x", kind: .prusaLink, host: "10.0.0.2"))).contains(.nozzleTemp))
        XCTAssertTrue(controlsFor(.markforged(MarkforgedAccount(id: "1", label: "x", accessKey: "a", secretKey: "b"))).isEmpty)
    }

    func testCameraFraming() throws {
        let packet = bambuAuthPacket("12345678")
        XCTAssertEqual(packet.count, 80)
        XCTAssertEqual([UInt8](packet.prefix(8)), [0x40, 0, 0, 0, 0, 0x30, 0, 0])
        XCTAssertEqual(String(decoding: packet[16..<20], as: UTF8.self), "bblp")
        XCTAssertEqual(String(decoding: packet[48..<56], as: UTF8.self), "12345678")

        var scanner = JPEGScanner()
        let stream = Data([1, 2, 0xFF, 0xD8, 5, 6, 0xFF, 0xD9, 9, 0xFF, 0xD8, 7, 0xFF, 0xD9, 0xFF])
        let frames = try scanner.feed(stream)
        XCTAssertEqual(frames, [Data([0xFF, 0xD8, 5, 6, 0xFF, 0xD9]), Data([0xFF, 0xD8, 7, 0xFF, 0xD9])])
    }

    func testPrintableFiles() {
        let elegoo = Account.elegoo(ElegooAccount(id: "e", label: "e", accessToken: "t", userId: "u"))
        XCTAssertTrue(printableBy(elegoo, fileName: "a.3MF"))
        XCTAssertFalse(printableBy(elegoo, fileName: "a.bgcode"))
        let prusa = Account.lan(LanPrinter(id: "p", label: "p", kind: .prusaLink, host: "h"))
        XCTAssertTrue(printableBy(prusa, fileName: "x.bgcode"))
        XCTAssertNotNil(printBlockedReason(.bambu(BambuAccount(id: "b", label: "b", accessToken: "t", uid: "1"))))
        XCTAssertNil(printBlockedReason(prusa))
    }
}
