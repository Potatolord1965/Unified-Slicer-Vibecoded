import XCTest
@testable import UnifiedCore

final class HandoffTests: XCTestCase {
    // Sealed by Unified Slicer's PhoneSignIn::seal (C++, OpenSSL) with key 00 01 … 1f and this id.
    let key = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
    let id = "AAECAwQFBgcICQoLDA0ODw"
    let sealed = Data(base64Encoded: "JubV3UPXYLep1kgRM+R2Qaov/rAOXDeUi9oyvgDgd2T+Ry5H4AFzsNI0s66rHRQW1XoPj4/zm4u6pW6gMoabIuboTE5hr/sQiRDRgxKHSMiKsveVLwlwpxiqZ0vI9NVlNbnJuMHzjmcREyxo7a2yaChecb1yJ7Hhr9PO1sCUtanVfJnBpOsDBxamxnjY3ELWEMt3V5ZeKy7PMgiCXw/zTnVIySvEekUdEUmUBDWiwnT9WuQk4ZqbGhtaWLPq2M8PQsaK/zXYZQ6FwAYwbA9QwPwKCK3bqnRdRyjHMHGpG9O85ImbfrBrwKuEH1aRUAWzlbAunrMNGHXEy6rt6vA5qz+hM5ed0l21mFgjcriY1f5AgkRNcx+FRUrN3qhUCoOp6PciXPqtty/gTWnq6xxhY0wFSYEbaDfxx9xH/tqJkwLCmTiseGAZXyiexqCYevMAR2ChCVEjOI7aEtzwbTaPFESHKaqmw5rpOrf0ldoNokRnrH2PjGO9+zne5+FFwVIjHRSlsejSjv7NlfSC5Ilr9VZ1b7g31CSuSyTrmwdTNV4gD+3pcpfwEecCF6vTBPCfwQyo2Xhw9E3/X3f8UbhoNxWE6Dl4UUKVfPKEmv4mYHcDjdcVZ/yUYx14Xgb+X7rJRJAuCX3Y5wriNVHNhQAJCqjuOifHr9kGKPlFiB/HQcJLlSaW5znAXaTVJYjSgOpMEZkigUBQVhkdFAo=")!

    func code(_ hosts: String = "192.168.1.20", port: Int = 5000) -> SignInCode {
        SignInCode.parse("unifiedslicer://signin?v=1&h=\(hosts)&p=\(port)&i=\(id)&k=\(key)")!
    }

    func testParsesCode() {
        let c = code("192.168.1.20,10.0.0.5")
        XCTAssertEqual(c.hosts, ["192.168.1.20", "10.0.0.5"])
        XCTAssertEqual(c.port, 5000)
        XCTAssertEqual(c.key.count, 32)
        XCTAssertNil(SignInCode.parse("https://example.com/?v=1"))
        XCTAssertNil(SignInCode.parse("unifiedslicer://signin?v=2&h=1.2.3.4&p=1&i=\(id)&k=\(key)"))
        XCTAssertNil(SignInCode.parse("unifiedslicer://signin?v=1&h=evil.example&p=1&i=\(id)&k=\(key)"))
        XCTAssertNil(SignInCode.parse("unifiedslicer://signin?v=1&h=10.1.2.3&p=1&i=\(id)&k=AAAA"))
        // Only addresses on the phone's own network: a link from a web page can't point the app anywhere else.
        XCTAssertNil(SignInCode.parse("unifiedslicer://signin?v=1&h=8.8.8.8&p=1&i=\(id)&k=\(key)"))
        XCTAssertNil(SignInCode.parse("unifiedslicer://signin?v=1&h=127.0.0.1&p=1&i=\(id)&k=\(key)"))
        XCTAssertEqual(code("8.8.8.8,172.20.0.9,172.32.0.1,100.64.1.2").hosts, ["172.20.0.9", "100.64.1.2"])
    }

    func testOpensWhatTheDesktopSealed() throws {
        let got = try SignInHandoff.open(code(), sealed: sealed)
        XCTAssertEqual(got.computer, "DESKTOP-1")
        XCTAssertEqual(got.accounts.count, 4) // the unknown "future" service is skipped
        guard case .bambu(let b) = got.accounts[0], case .elegoo(let e) = got.accounts[1],
              case .creality(let c) = got.accounts[2], case .markforged(let m) = got.accounts[3] else {
            return XCTFail("Unexpected account kinds")
        }
        XCTAssertEqual([b.label, b.region, b.accessToken, b.refreshToken, b.uid], ["me@x", "global", "bt", "br", "42"])
        XCTAssertEqual([e.region, e.accessToken, e.refreshToken, e.userId], ["CN", "et", "er", "7"])
        XCTAssertEqual(e.accessExpireMs, 1_763_000_000_000)
        XCTAssertEqual([c.region, c.token, c.userId, c.deviceUid], ["china", "ct", "9", "duid"])
        XCTAssertEqual([m.accessKey, m.secretKey], ["ak", "sk"])
    }

    func testRejectsTamperedOrWrongCode() {
        var tampered = sealed
        tampered[20] ^= 1
        XCTAssertThrowsError(try SignInHandoff.open(code(), sealed: tampered)) { XCTAssertTrue($0 is HandoffError) }
        let otherId = SignInCode.parse("unifiedslicer://signin?v=1&h=10.1.2.3&p=1&i=BBECAwQFBgcICQoLDA0ODw&k=\(key)")!
        XCTAssertThrowsError(try SignInHandoff.open(otherId, sealed: sealed)) { XCTAssertTrue($0 is HandoffError) }
    }

    func testFetchesFromTheFirstAddressThatAnswers() async throws {
        let sealed = self.sealed
        let http = FakeHTTP { r in
            if r.url.host == "192.168.1.20" { throw IOError("No route") }
            return HTTPResponse(status: 200, body: sealed)
        }
        let got = try await SignInHandoff(http: http).fetch(code("192.168.1.20,10.0.0.5"))
        XCTAssertEqual(got.accounts.count, 4)
        XCTAssertEqual(http.requests.current.last?.url.absoluteString, "http://10.0.0.5:5000/signin/\(id)")
    }

    func testUsedCodeSaysSo() async {
        let http = FakeHTTP { _ in HTTPResponse(status: 404) }
        do {
            _ = try await SignInHandoff(http: http).fetch(code())
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(readable(error).contains("already used"))
        }
    }

    func testOversizedAnswerIsRefused() async {
        let http = FakeHTTP { _ in throw ResponseTooLarge() }
        do {
            _ = try await SignInHandoff(http: http).fetch(code())
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(readable(error).contains("too large"))
        }
    }

    func testImportReplacesTheSameLogin() throws {
        let saved: [Account] = [.bambu(BambuAccount(id: "bambu-old", label: "old", accessToken: "x", uid: "42"))]
        let incoming = try SignInHandoff.open(code(), sealed: sealed).accounts
        let merged = mergeAccounts(saved: saved, incoming: incoming)
        XCTAssertEqual(merged[0].id, "bambu-old")
        guard case .bambu(let b) = merged[0] else { return XCTFail("Expected Bambu") }
        XCTAssertEqual(b.accessToken, "bt")
        XCTAssertFalse(merged.dropFirst().contains { $0.id == "bambu-old" })
    }
}
