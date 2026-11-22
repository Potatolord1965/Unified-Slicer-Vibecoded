import XCTest
@testable import UnifiedCore

final class FakeSource: PrinterSource, @unchecked Sendable {
    let account: Account
    let fail = Locked<Error?>(nil)
    let closed = Locked(false)

    init(_ account: Account) { self.account = account }

    func refresh() async throws -> [PrinterStatus] {
        if let e = fail.current { throw e }
        return [PrinterStatus(accountId: account.id, deviceId: "d", name: account.label, brand: .other, via: "test", state: .idle)]
    }

    func close() { closed.set(true) }
}

final class HubTests: XCTestCase {
    func testKeepsLastGoodAndReportsProblems() async {
        let fakes = Locked([String: FakeSource]())
        let hub = PrinterHub(SourceContext(http: noHTTP())) { a, _ in
            let f = FakeSource(a)
            fakes.with { $0[a.id] = f }
            return f
        }
        let a = Account.lan(LanPrinter(id: "a", label: "A", kind: .octoprint, host: "h"))
        let b = Account.lan(LanPrinter(id: "b", label: "B", kind: .octoprint, host: "h"))
        await hub.setAccounts([a, b])
        let first = await hub.refresh()
        XCTAssertEqual(first.printers.count, 2)

        fakes.current["b"]?.fail.set(AuthError("expired"))
        let snap = await hub.refresh()
        XCTAssertEqual(snap.printers.count, 2)
        XCTAssertEqual(snap.problems["b"]?.signInExpired, true)

        await hub.setAccounts([a])
        XCTAssertEqual(fakes.current["b"]?.closed.current, true)
        let last = await hub.refresh()
        XCTAssertEqual(last.printers.map(\.accountId), ["a"])
    }

    func testSlowSourceTimesOut() async {
        final class Slow: PrinterSource, @unchecked Sendable {
            let account: Account
            init(_ a: Account) { account = a }
            func refresh() async throws -> [PrinterStatus] {
                try await pause(10)
                return []
            }
            func close() {}
        }
        let hub = PrinterHub(SourceContext(http: noHTTP())) { a, _ in Slow(a) }
        await hub.setAccounts([.lan(LanPrinter(id: "s", label: "S", kind: .moonraker, host: "h"))])
        let snap = await hub.refresh(timeout: 0.3)
        XCTAssertEqual(snap.problems["s"]?.message, "Timed out")
    }
}
