import XCTest
@testable import UnifiedCore

final class PrintTests: XCTestCase {
    func gcode() throws -> URL { try tempFile("job.gcode", "G28\nG1 X10\n") }

    func testMoonrakerUploadsAndStarts() async throws {
        let body = Locked("")
        let http = FakeHTTP { r in
            if case .file(let url)? = r.body { body.set((try? String(contentsOf: url)) ?? "") }
            return FakeHTTP.ok(#"{"result":{"print_started":true}}"#)
        }
        let src = MoonrakerSource(LanPrinter(id: "l", label: "Voron", kind: .moonraker, host: "http://10.0.0.9:7125/", secret: "key"), SourceContext(http: http))
        let seen = Locked([Int]())
        try await src.sendPrint(deviceId: "d", job: PrintJob(file: try gcode(), name: "cube.gcode")) { pct, _ in
            if let p = pct { seen.with { $0.append(p) } }
        }
        let req = try XCTUnwrap(http.requests.current.first)
        XCTAssertEqual(req.url.absoluteString, "http://10.0.0.9:7125/server/files/upload")
        XCTAssertEqual(req.header("X-Api-Key"), "key")
        XCTAssertTrue(req.header("Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        XCTAssertTrue(body.current.contains("filename=\"cube.gcode\""))
        XCTAssertTrue(body.current.contains("name=\"print\""))
        XCTAssertTrue(body.current.contains("G1 X10"))
        XCTAssertEqual(seen.current.last, 100)
    }

    func testOctoPrintReportsRefusal() async throws {
        let http = FakeHTTP { _ in HTTPResponse(status: 409, body: Data("busy".utf8)) }
        let src = OctoPrintSource(LanPrinter(id: "l", label: "Ender", kind: .octoprint, host: "octopi.local", secret: "key"), SourceContext(http: http))
        do {
            try await src.sendPrint(deviceId: "d", job: PrintJob(file: try gcode(), name: "cube.gcode")) { _, _ in }
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(readable(error).contains("409"))
        }
    }

    func testUnreachableLanPrinterIsOffline() async throws {
        let src = OctoPrintSource(LanPrinter(id: "l", label: "Ender", kind: .octoprint, host: "octopi.local"), SourceContext(http: noHTTP()))
        let list = try await src.refresh()
        XCTAssertEqual(list.first?.state, .offline)
    }

    func testCrealityObjectKey() {
        let key = CrealityCloudSource.objectKey("cube", "abc")
        XCTAssertNotNil(key.range(of: #"^model/slice/[0-9A-F]{32}\.gcode\.gz$"#, options: .regularExpression))
    }

    func testElegooChannelMatchesRepliesAndErrors() async throws {
        final class FakeRtm: RtmConnector, RtmSession, @unchecked Sendable {
            let sent = Locked([(String, String)]())
            let errorCode = Locked(0)
            let deliver = Locked<(@Sendable (String, String) -> Void)?>(nil)

            func connect(appId: String, userId: String, token: String, onMessage: @escaping @Sendable (String, String) -> Void) async throws -> RtmSession {
                deliver.set(onMessage)
                return self
            }

            func publish(peer: String, message: String) async throws {
                sent.with { $0.append((peer, message)) }
                let id = json(message).int("id") ?? 0
                let onMessage = deliver.current!
                onMessage("someone-else", #"{"id":\#(id),"result":{"error_code":99}}"#) // ignored: not the printer
                onMessage(peer, #"{"id":\#(id),"method":1057,"result":{"error_code":\#(errorCode.current)}}"#)
            }

            func close() {}
        }
        let rtm = FakeRtm()
        let ch = try await ElegooPrinterChannel.open(rtm: rtm, agoraUserId: "777", rtmUserId: "rtm777", rtmToken: "tok", serial: "SN1")
        let reply = try await ch.request(ElegooPrinterChannel.mDownloadFile)
        XCTAssertNotNil(reply)
        XCTAssertEqual(rtm.sent.current.map(\.0), ["777SN1"])
        rtm.deliver.current?("777SN1", #"{"method":6006,"result":{"progress":40,"status":0}}"#)
        XCTAssertEqual(ch.download?.str("progress"), "40")
        rtm.errorCode.set(1026)
        do {
            try await ch.request(ElegooPrinterChannel.mStartPrint)
            XCTFail("Expected an error")
        } catch let e as ElegooPrinterError {
            XCTAssertEqual(e.code, 1026)
        }
    }
}
