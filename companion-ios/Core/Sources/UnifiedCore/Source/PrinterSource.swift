import Foundation

/// Reads the printers behind one `Account`. Sources may keep connections open between refreshes
/// (MQTT); `close` releases them.
public protocol PrinterSource: AnyObject, Sendable {
    /// The account as the source last knew it; a source that renews its token updates it.
    var account: Account { get }

    /// Current status of every printer of the account. Throws on network or sign-in errors.
    func refresh() async throws -> [PrinterStatus]

    func close()
}

/// What sources share: the HTTP client, a callback for sources that renew their tokens (so the
/// app can save the new account), and the messaging SDK that Elegoo's cloud prints need.
public struct SourceContext: Sendable {
    public var http: HTTPClient
    public var onAccountUpdated: @Sendable (Account) -> Void
    public var rtm: RtmConnector?

    public init(http: HTTPClient, onAccountUpdated: @escaping @Sendable (Account) -> Void = { _ in }, rtm: RtmConnector? = nil) {
        self.http = http
        self.onAccountUpdated = onAccountUpdated
        self.rtm = rtm
    }
}

/// A sliced file on the phone, ready to send. `name` is the name the printer shows.
public struct PrintJob: Sendable {
    public var file: URL
    public var name: String
    public init(file: URL, name: String) {
        self.file = file
        self.name = name
    }
}

/// Progress of a send: `percent` 0...100 when known, `status` when the step changes.
public typealias SendProgress = @Sendable (_ percent: Int?, _ status: String?) -> Void

/// A source whose printers can be sent a print. Phones cannot slice, so files must be printer-ready.
public protocol PrintCapable {
    /// Uploads `job` to the printer `deviceId` and starts it. Throws with a readable message on failure.
    func sendPrint(deviceId: String, job: PrintJob, progress: @escaping SendProgress) async throws
}

/// Whether printers of `account` can be sent the file `fileName` from this app.
public func printableBy(_ account: Account, fileName: String) -> Bool {
    switch account {
    case .elegoo: return hasExtension(fileName, ".gcode", ".3mf")
    case .creality: return hasExtension(fileName, ".gcode")
    case .lan(let p):
        switch p.kind {
        case .elegooCC2: return hasExtension(fileName, ".gcode")
        case .moonraker, .octoprint: return hasExtension(fileName, ".gcode", ".gco", ".g")
        case .prusaLink: return hasExtension(fileName, ".gcode", ".bgcode")
        // LAN-mode sends need Bambu's developer mode and FTPS; not supported.
        case .bambu: return false
        }
    // Bambu only accepts cloud prints from its own apps; Eiger slices STL itself.
    case .bambu, .markforged: return false
    }
}

/// Why `account`'s printers take no prints from this app, for brands where that is by design.
public func printBlockedReason(_ account: Account) -> String? {
    switch account {
    case .bambu:
        return "Bambu printers only accept prints from Bambu's own apps. Use Print in MakerWorld to hand the job to Bambu Handy."
    case .lan(let p) where p.kind == .bambu:
        return "Bambu printers only accept prints from Bambu's own apps. Use Print in MakerWorld to hand the job to Bambu Handy."
    case .markforged:
        return "Markforged printers only print jobs sliced in Eiger."
    default:
        return nil
    }
}

func hasExtension(_ fileName: String, _ extensions: String...) -> Bool {
    let lower = fileName.lowercased()
    return extensions.contains { lower.hasSuffix($0) }
}

/// Real-time messaging to printers behind Elegoo's cloud (Agora RTM). The app supplies the SDK.
public protocol RtmConnector: Sendable {
    /// Logs in and returns a session; `onMessage` gets every incoming message with its publisher id.
    func connect(appId: String, userId: String, token: String, onMessage: @escaping @Sendable (_ publisher: String, _ body: String) -> Void) async throws -> RtmSession
}

public protocol RtmSession: AnyObject, Sendable {
    /// Sends `message` to one user (a printer's messaging id).
    func publish(peer: String, message: String) async throws
    func close()
}

/// Creates the source for an account.
public func createSource(_ account: Account, _ ctx: SourceContext) -> PrinterSource {
    switch account {
    case .bambu(let a): return BambuCloudSource(a, ctx)
    case .elegoo(let a): return ElegooCloudSource(a, ctx)
    case .creality(let a): return CrealityCloudSource(a, ctx)
    case .markforged(let a): return EigerSource(a, ctx)
    case .lan(let p):
        switch p.kind {
        case .bambu: return BambuLanSource(p)
        case .elegooCC2: return ElegooLanSource(p, ctx)
        case .moonraker: return MoonrakerSource(p, ctx)
        case .octoprint: return OctoPrintSource(p, ctx)
        case .prusaLink: return PrusaLinkSource(p, ctx)
        }
    }
}

/// Waits until `ready` or `timeout` seconds pass.
func awaitCondition(timeout: Double, _ ready: () -> Bool) async throws {
    _ = try await poll(timeout: timeout, every: 0.15) { ready() ? true : nil }
}
