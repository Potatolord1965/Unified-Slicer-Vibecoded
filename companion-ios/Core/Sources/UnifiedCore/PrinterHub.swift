import Foundation

/// Why an account's printers could not be read.
public struct AccountProblem: Equatable, Sendable {
    public let accountId: String
    public let message: String
    public let signInExpired: Bool

    public init(accountId: String, message: String, signInExpired: Bool) {
        self.accountId = accountId
        self.message = message
        self.signInExpired = signInExpired
    }
}

public struct HubSnapshot: Equatable, Sendable {
    public var printers: [PrinterStatus]
    public var problems: [String: AccountProblem]
    public var at: Date

    public init(printers: [PrinterStatus] = [], problems: [String: AccountProblem] = [:], at: Date = Date()) {
        self.printers = printers
        self.problems = problems
        self.at = at
    }
}

/// Keeps one `PrinterSource` per account and refreshes them all in parallel. Accounts that fail
/// keep their last known printers so a dropped connection does not empty the list.
public actor PrinterHub {
    public typealias Factory = @Sendable (Account, SourceContext) -> PrinterSource

    private let ctx: SourceContext
    private let factory: Factory
    private var order: [String] = []
    private var sources: [String: (account: Account, source: PrinterSource)] = [:]
    private var lastGood: [String: [PrinterStatus]] = [:]

    public init(_ ctx: SourceContext, factory: @escaping Factory = { createSource($0, $1) }) {
        self.ctx = ctx
        self.factory = factory
    }

    /// Makes the hub follow `accounts`: new ones get a source, removed or edited ones are closed.
    public func setAccounts(_ accounts: [Account]) {
        let wanted = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, entry) in sources {
            let now = wanted[id]
            // A source that renewed its own token reports an updated account; only a real edit restarts it.
            if now == nil || (now != entry.account && now != entry.source.account) {
                entry.source.close()
                sources[id] = nil
                lastGood[id] = nil
            }
        }
        for a in accounts where sources[a.id] == nil {
            sources[a.id] = (a, factory(a, ctx))
        }
        // Keep the user's order.
        var seen = Set<String>()
        order = accounts.map(\.id).filter { seen.insert($0).inserted }
    }

    public func refresh(timeout: Double = 25) async -> HubSnapshot {
        let current = order.compactMap { sources[$0]?.source }
        let results = await withTaskGroup(of: (String, Result<[PrinterStatus], Error>).self) { group in
            for src in current {
                group.addTask {
                    let id = src.account.id
                    do {
                        let list = try await withTimeout(timeout, message: "Timed out") { try await src.refresh() }
                        return (id, .success(list))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }
            var out = [String: Result<[PrinterStatus], Error>]()
            for await (id, r) in group { out[id] = r }
            return out
        }
        var printers = [PrinterStatus]()
        var problems = [String: AccountProblem]()
        for src in current {
            let id = src.account.id
            guard let r = results[id] else { continue }
            switch r {
            case .success(let list):
                lastGood[id] = list
                printers += list
            case .failure(let e):
                printers += lastGood[id] ?? []
                problems[id] = AccountProblem(accountId: id, message: readable(e), signInExpired: e is AuthError)
            }
        }
        return HubSnapshot(printers: printers, problems: problems)
    }

    private func source(_ accountId: String) throws -> PrinterSource {
        guard let s = sources[accountId]?.source else { throw IOError("This printer is no longer on your accounts") }
        return s
    }

    /// Sends `job` to a printer and starts it. Throws with a readable message on failure.
    public func sendPrint(accountId: String, deviceId: String, job: PrintJob, progress: @escaping SendProgress) async throws {
        let src = try source(accountId)
        guard let capable = src as? PrintCapable else { throw IOError("\(src.account.kindLabel) printers cannot be sent prints from this app") }
        try await capable.sendPrint(deviceId: deviceId, job: job, progress: progress)
    }

    /// Sends `command` to a printer. Throws with a readable message when it is refused.
    public func control(accountId: String, deviceId: String, command: PrinterCommand) async throws {
        let src = try source(accountId)
        guard let target = src as? Controllable else { throw IOError("\(src.account.kindLabel) printers cannot be controlled from this app") }
        try await target.control(deviceId: deviceId, command: command)
    }

    /// The camera of a printer, or nil when this app cannot show one for it.
    public func camera(accountId: String, deviceId: String) async throws -> CameraFeed? {
        guard let src = sources[accountId]?.source as? CameraCapable else { return nil }
        return try await src.camera(deviceId: deviceId)
    }

    /// Files kept on a printer; throws when the printer cannot list them.
    public func files(accountId: String, deviceId: String) async throws -> [PrinterFile] {
        try await browsable(accountId).files(deviceId: deviceId)
    }

    public func printFile(accountId: String, deviceId: String, file: PrinterFile) async throws {
        try await browsable(accountId).printFile(deviceId: deviceId, file: file)
    }

    /// Past prints, newest first; throws when the service keeps no history this app can read.
    public func history(accountId: String, deviceId: String) async throws -> [PastPrint] {
        let src = try source(accountId)
        guard let h = src as? HistoryCapable else { throw IOError("\(src.account.kindLabel) keeps no print history this app can read") }
        return try await h.history(deviceId: deviceId)
    }

    private func browsable(_ accountId: String) throws -> FileBrowsable {
        let src = try source(accountId)
        guard let b = src as? FileBrowsable else { throw IOError("\(src.account.kindLabel) printers cannot list their files in this app") }
        return b
    }

    /// Drops open connections (e.g. when the app goes to the background); the next refresh reconnects.
    public func disconnect() {
        for (id, entry) in sources {
            entry.source.close()
            let a = entry.source.account
            sources[id] = (a, factory(a, ctx))
        }
    }

    public func close() {
        for entry in sources.values { entry.source.close() }
        sources = [:]
        order = []
    }
}
