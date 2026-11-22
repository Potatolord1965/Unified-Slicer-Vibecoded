import BackgroundTasks
import SwiftUI
import UIKit
import UnifiedCore

enum Tab: Hashable {
    case printers, models, accounts, settings
}

enum PrinterRoute: Hashable {
    case printer(String)
    case files(String)
    case history(String)
}

/// Screens of the add / sign-in flow. `replace` is the id of the account being edited.
enum AddRoute: Hashable {
    case bambu(replace: String?)
    case elegoo(replace: String?)
    case creality(replace: String?)
    case markforged(replace: String?)
    case lan(LanKind, replace: String?)
    case scan
    case signIn(code: String, ask: Bool)

    static func edit(_ a: Account) -> AddRoute {
        switch a {
        case .bambu(let x): return .bambu(replace: x.id)
        case .elegoo(let x): return .elegoo(replace: x.id)
        case .creality(let x): return .creality(replace: x.id)
        case .markforged(let x): return .markforged(replace: x.id)
        case .lan(let x): return .lan(x.kind, replace: x.id)
        }
    }
}

enum Sheet: Identifiable {
    /// The add / sign-in flow, starting at `root` (nil: the list of choices).
    case add(AddRoute?)
    case send

    var id: String {
        switch self {
        case .add(let r): return "add-\(String(describing: r))"
        case .send: return "send"
        }
    }
}

struct SendState: Equatable {
    var printer: String
    var file: String
    var percent: Int
    var status: String
    var running = true
    var done = false
    var error: String?
}

/// Live printer status and app state for the UI. The app drives `refresh` on a timer while it is
/// visible, and the background check uses `backgroundCheck`, so each account only ever has one client.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    static let refreshTaskId = "app.unifiedslicer.monitor.refresh"

    let settings = AppSettings()
    private let store = AccountStore()
    private let notifier: TransitionNotifier
    private let hub: PrinterHub
    let http = URLSessionHTTP()

    @Published private(set) var accounts: [Account]
    @Published private(set) var snapshot: HubSnapshot?
    @Published private(set) var refreshing = false
    /// A printer-ready file waiting for the user to pick a printer.
    @Published private(set) var pendingFile: PrintJob?
    /// The send in progress or just finished; nil when there is none.
    @Published private(set) var send: SendState?
    @Published var tab: Tab = .printers
    @Published var printersPath: [PrinterRoute] = []
    @Published var sheet: Sheet?
    @Published var alert: String?

    private var running = false
    private var inForeground = false
    private var liveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?

    private init() {
        notifier = TransitionNotifier(settings: settings)
        accounts = store.load()
        hub = PrinterHub(SourceContext(
            http: http,
            onAccountUpdated: { a in Task { @MainActor in AppModel.shared.accountRenewed(a) } },
            rtm: AgoraRtmConnector.shared
        ))
        let initial = accounts
        Task { await hub.setAccounts(initial) }
    }

    // MARK: Accounts

    private func setAccounts(_ list: [Account]) {
        accounts = list
        store.save(list)
        Task {
            await hub.setAccounts(list)
            if inForeground { await refresh() }
        }
    }

    func saveAccount(_ a: Account) {
        setAccounts(accounts.filter { $0.id != a.id } + [a])
        sheet = nil
        tab = .printers
        printersPath = []
    }

    func removeAccount(_ id: String) {
        setAccounts(accounts.filter { $0.id != id })
    }

    func importAccounts(_ incoming: [Account]) {
        var list = accounts
        for a in mergeAccounts(saved: accounts, incoming: incoming) {
            list = list.filter { $0.id != a.id } + [a]
        }
        setAccounts(list)
        sheet = nil
        tab = .accounts
    }

    /// A source renewed its token: save it without restarting the source.
    private func accountRenewed(_ a: Account) {
        guard accounts.contains(where: { $0.id == a.id }) else { return }
        accounts = accounts.map { $0.id == a.id ? a : $0 }
        store.save(accounts)
    }

    func account(of p: PrinterStatus) -> Account? { accounts.first { $0.id == p.accountId } }

    func printer(_ key: String) -> PrinterStatus? { snapshot?.printers.first { $0.key == key } }

    // MARK: Live view

    /// Polls while the app is on screen.
    func startLive() {
        inForeground = true
        guard liveTask == nil else { return }
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(nanoseconds: UInt64(max(self.settings.refreshSeconds, 2)) * 1_000_000_000)
            }
        }
    }

    /// Drops connections when the app leaves the screen, unless a send still needs them.
    func stopLive() {
        inForeground = false
        liveTask?.cancel()
        liveTask = nil
        if send?.running != true { Task { await hub.disconnect() } }
        scheduleBackgroundCheck()
    }

    /// Refreshes every account; a call while one is running is dropped.
    func refresh() async {
        guard !running else { return }
        running = true
        refreshing = true
        defer {
            running = false
            refreshing = false
        }
        let snap = await hub.refresh()
        snapshot = snap
        notifier.process(snap)
    }

    func refreshSoon() {
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await refresh()
        }
    }

    /// One check while the app is closed, on the live view's hub: two clients renewing one Elegoo
    /// session at once would sign it out.
    func backgroundCheck() async {
        accounts = store.load()
        await hub.setAccounts(accounts)
        guard !running else { return }
        running = true
        let snap = await hub.refresh(timeout: 20)
        snapshot = snap
        notifier.process(snap)
        running = false
        if !inForeground && send?.running != true { await hub.disconnect() }
    }

    func scheduleBackgroundCheck() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: AppModel.refreshTaskId)
        guard settings.backgroundChecks, !accounts.isEmpty else { return }
        let request = BGAppRefreshTaskRequest(identifier: AppModel.refreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: Sending

    func offer(_ job: PrintJob) {
        pendingFile = job
        if send?.running != true { send = nil }
        sheet = .send
    }

    /// Opens a file handed to the app (Files, Share, AirDrop) or picked in it.
    func openFile(_ url: URL) {
        do {
            let job = try PrintFiles.importFile(url)
            if PrintFiles.isPrinterReady(job.name) {
                tab = .models
                offer(job)
            } else {
                alert = "\(job.name) is not a sliced file. Pick G-code made for your printer."
            }
        } catch {
            alert = readable(error)
        }
    }

    /// Sends outside any screen, so closing the sheet does not abort an upload. iOS gives a send
    /// that is still running when the app leaves the screen a little time to finish.
    func startSend(_ printer: PrinterStatus, _ job: PrintJob) {
        if send?.running == true { return }
        send = SendState(printer: printer.name, file: job.name, percent: 0, status: "Starting…")
        let background = UIApplication.shared.beginBackgroundTask(withName: "Send print") { [weak self] in
            self?.sendTask?.cancel()
        }
        let hub = self.hub
        sendTask = Task { [weak self] in
            defer { UIApplication.shared.endBackgroundTask(background) }
            do {
                try await hub.sendPrint(accountId: printer.accountId, deviceId: printer.deviceId, job: job) { pct, status in
                    Task { @MainActor in
                        guard let self, var s = self.send, s.running else { return }
                        if let pct { s.percent = pct }
                        if let status { s.status = status }
                        self.send = s
                    }
                }
                self?.send?.percent = 100
                self?.send?.status = "Print started"
                self?.send?.running = false
                self?.send?.done = true
                await self?.refresh()
            } catch is CancellationError {
                self?.send?.running = false
                self?.send?.error = "Cancelled"
            } catch {
                self?.send?.running = false
                self?.send?.error = Task.isCancelled ? "Cancelled" : readable(error)
            }
        }
    }

    func cancelSend() { sendTask?.cancel() }

    func clearSend() {
        if send?.running != true { send = nil }
    }

    /// Closes the send sheet: a finished send is forgotten, a failed one goes back to the printer choice.
    func closeSend() {
        guard let s = send, !s.running else {
            sheet = nil
            return
        }
        if s.done {
            send = nil
            pendingFile = nil
            sheet = nil
        } else {
            send = nil
        }
    }

    // MARK: Printers

    /// Sends `command`; returns why it failed, or nil when the printer took it.
    func control(_ p: PrinterStatus, _ command: PrinterCommand) async -> String? {
        do {
            try await hub.control(accountId: p.accountId, deviceId: p.deviceId, command: command)
            refreshSoon()
            return nil
        } catch {
            return readable(error)
        }
    }

    /// The camera of `p`, or nil when the app cannot show one for it. Throws when it is switched off.
    func camera(_ p: PrinterStatus) async throws -> CameraFeed? {
        try await hub.camera(accountId: p.accountId, deviceId: p.deviceId)
    }

    func files(_ p: PrinterStatus) async throws -> [PrinterFile] {
        try await hub.files(accountId: p.accountId, deviceId: p.deviceId)
    }

    /// Starts `file` on `p`; returns why it failed, or nil.
    func printFile(_ p: PrinterStatus, _ file: PrinterFile) async -> String? {
        do {
            try await hub.printFile(accountId: p.accountId, deviceId: p.deviceId, file: file)
            refreshSoon()
            return nil
        } catch {
            return readable(error)
        }
    }

    func history(_ p: PrinterStatus) async throws -> [PastPrint] {
        try await hub.history(accountId: p.accountId, deviceId: p.deviceId)
    }

    // MARK: Links

    func openPrinter(_ key: String) {
        sheet = nil
        tab = .printers
        printersPath = [.printer(key)]
    }

    /// unifiedslicer://signin?… from the camera app, or a file opened in this app.
    func handle(_ url: URL) {
        if url.isFileURL {
            openFile(url)
        } else if url.scheme?.lowercased() == "unifiedslicer", url.host?.lowercased() == "signin" {
            // Any web page or app can open this link, so nothing is fetched until the person agrees.
            sheet = .add(.signIn(code: url.absoluteString, ask: true))
        }
    }
}
