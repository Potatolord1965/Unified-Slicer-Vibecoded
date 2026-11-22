import Compression
import XCTest
@testable import UnifiedCore

final class NetTests: XCTestCase {
    func testAccountRoundTrip() throws {
        let list: [Account] = [
            .bambu(BambuAccount(id: "b", label: "me@x", accessToken: "t", uid: "1")),
            .lan(LanPrinter(id: "l", label: "Voron", kind: .moonraker, host: "10.0.0.2:7125")),
            .elegoo(ElegooAccount(id: "e", label: "E", region: "CN", accessToken: "a", refreshToken: "r", accessExpireMs: 5, userId: "u")),
            .creality(CrealityAccount(id: "c", label: "C", token: "t", userId: "9", deviceUid: "d")),
            .markforged(MarkforgedAccount(id: "m", label: "M", accessKey: "ak", secretKey: "sk")),
        ]
        let data = try JSONEncoder().encode(list)
        XCTAssertEqual(try JSONDecoder().decode([Account].self, from: data), list)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""type":"lan""#))
        XCTAssertTrue(text.contains(#""kind":"MOONRAKER""#))
    }

    func testJSONParser() {
        let j = json(#" {"a":[1,2.5,-3e2,true,false,null],"s":"x\"y\\z\né😀","o":{}} "#)
        XCTAssertEqual(j.arr("a")?.count, 6)
        XCTAssertEqual(j.arr("a")?[1].asNumber, 2.5)
        XCTAssertEqual(j.arr("a")?[2].asNumber, -300)
        XCTAssertEqual(j.str("s"), "x\"y\\z\né😀")
        XCTAssertNil(JSON.parse("{\"a\":1} x"))
        XCTAssertNil(JSON.parse("{'a':1}"))
        XCTAssertNil(JSON.parse(""))
        // Numbers keep their text, so ids and codes read back exactly.
        XCTAssertEqual(json(#"{"id":12345678901234567890}"#).str("id"), "12345678901234567890")
        XCTAssertEqual(json(#"{"n":"42"}"#).int("n"), 42)
        XCTAssertEqual(json(#"{"b":1}"#).bool("b"), true)
        XCTAssertNil(json(#"{"s":""}"#).str("s"))
        let round = json(#"{"b":[1,"two",{"c":null}],"a":"q\"\n"}"#)
        XCTAssertEqual(round.serialized, #"{"a":"q\"\n","b":[1,"two",{"c":null}]}"#)
        XCTAssertEqual(JSON.parse(round.serialized), round)
    }

    func testMQTTCodec() throws {
        let connect = MQTTPacket.connect(clientId: "c", username: "u", password: "p", keepAlive: 30)
        XCTAssertEqual([UInt8](connect), [0x10, 19, 0, 4, 77, 81, 84, 84, 4, 0xC2, 0, 30, 0, 1, 99, 0, 1, 117, 0, 1, 112])
        XCTAssertEqual([UInt8](MQTTPacket.remainingLength(321)), [0xC1, 0x02])
        let sub = MQTTPacket.subscribe(packetId: 1, topics: ["a/b"])
        XCTAssertEqual([UInt8](sub), [0x82, 8, 0, 1, 0, 3, 97, 47, 98, 0])
        let pub = MQTTPacket.publish(topic: "t", payload: Data("hi".utf8))
        XCTAssertEqual(try MQTTPacket.decode(header: pub[0], body: pub.dropFirst(2)),
                       .publish(topic: "t", payload: Data("hi".utf8), qos: 0, packetId: nil))
        XCTAssertEqual(try MQTTPacket.decode(header: 0x32, body: Data([0, 1, 116, 0, 9, 120])),
                       .publish(topic: "t", payload: Data("x".utf8), qos: 1, packetId: 9))
        XCTAssertEqual(try MQTTPacket.decode(header: 0x20, body: Data([0, 5])), .connAck(returnCode: 5))
        XCTAssertThrowsError(try MQTTPacket.decode(header: 0x30, body: Data([0, 9, 1])))
    }

    func testHashes() {
        XCTAssertEqual(CRC32.of(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(hmacSHA1(key: Data("Jefe".utf8), message: Data("what do ya want for nothing?".utf8)).base64EncodedString(), "7/zfauXrL6LSdBbV8YTfnCWafHk=")
        XCTAssertEqual(md5(Data("abc".utf8)).hex(), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(Data([0xAB, 0x01]).hex(upper: true), "AB01")
        XCTAssertEqual(httpDate(Date(timeIntervalSince1970: 1_794_283_506)), "Tue, 10 Nov 2026 04:05:06 GMT")
        XCTAssertEqual(CrealityCloudSource.ossSignature("Jefe", "what do ya want for nothing?"), "7/zfauXrL6LSdBbV8YTfnCWafHk=")
        XCTAssertTrue(CrealityCloudSource.objectKey("cube", "abc").hasPrefix("model/slice/"))
        XCTAssertTrue(CrealityCloudSource.objectKey("cube", "abc").hasSuffix(".gcode.gz"))
    }

    func testGzip() throws {
        let text = String(repeating: "G1 X10 Y10 E0.5\n", count: 5000)
        let src = try tempFile("a.gcode", text)
        let gz = src.deletingLastPathComponent().appendingPathComponent("a.gcode.gz")
        try gzip(src, to: gz)
        let data = try Data(contentsOf: gz)
        XCTAssertEqual([UInt8](data.prefix(3)), [0x1F, 0x8B, 0x08])
        XCTAssertLessThan(data.count, text.utf8.count / 4)
        let trailer = [UInt8](data.suffix(8))
        let crc = UInt32(trailer[0]) | UInt32(trailer[1]) << 8 | UInt32(trailer[2]) << 16 | UInt32(trailer[3]) << 24
        let size = UInt32(trailer[4]) | UInt32(trailer[5]) << 8 | UInt32(trailer[6]) << 16 | UInt32(trailer[7]) << 24
        XCTAssertEqual(crc, CRC32.of(Data(text.utf8)))
        XCTAssertEqual(Int(size), text.utf8.count)
        // The middle is raw DEFLATE.
        let deflated = data.subdata(in: 10..<(data.count - 8))
        var out = Data()
        var offset = 0
        let filter = try InputFilter<Data>(.decompress, using: .zlib) { length in
            let end = min(offset + length, deflated.count)
            defer { offset = end }
            return deflated.subdata(in: offset..<end)
        }
        while let chunk = try filter.readData(ofLength: 65536), !chunk.isEmpty { out.append(chunk) }
        XCTAssertEqual(String(decoding: out, as: UTF8.self), text)
    }

    func testAddresses() {
        XCTAssertEqual(baseUrl("192.168.1.5:7125/"), "http://192.168.1.5:7125")
        XCTAssertEqual(baseUrl("HTTPS://x.local"), "HTTPS://x.local")
        XCTAssertEqual(bareHost("http://10.0.0.2:7125/path"), "10.0.0.2")
        XCTAssertEqual(bareHost("[fe80::1]:80"), "fe80::1")
        XCTAssertEqual(formEncode("a b+c/é"), "a%20b%2Bc%2F%C3%A9")
        XCTAssertEqual(formatMM(-0.1), "-0.1")
        XCTAssertEqual(formatMM(10), "10")
    }

    func testTimeoutAndPoll() async throws {
        do {
            _ = try await withTimeout(0.2) { () async throws -> Int in
                try await pause(5)
                return 1
            }
            XCTFail("Expected a time-out")
        } catch is TimedOut {}
        let flag = Locked(false)
        Task {
            try await pause(0.2)
            flag.set(true)
        }
        let got = try await poll(timeout: 3, every: 0.05) { flag.current ? 7 : nil }
        XCTAssertEqual(got, 7)
        let none: Int? = try await poll(timeout: 0.2) { nil }
        XCTAssertNil(none)
    }

    func testBambuCAsLoad() {
        XCTAssertEqual(bambuPrinterCAs.count, 5)
    }
}
