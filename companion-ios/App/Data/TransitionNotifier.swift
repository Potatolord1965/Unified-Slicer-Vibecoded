import Foundation
import UnifiedCore
import UserNotifications

/// Remembers each printer's last state and posts a notification when a print finishes, fails or
/// pauses. Shared by the live view and the background check so neither notifies twice.
final class TransitionNotifier {
    static let printerKey = "printer"
    private let settings: AppSettings
    private let defaults = UserDefaults.standard
    private let storeKey = "last_states"

    init(settings: AppSettings) { self.settings = settings }

    func process(_ snapshot: HubSnapshot) {
        var states = defaults.dictionary(forKey: storeKey) as? [String: String] ?? [:]
        for p in snapshot.printers {
            // A printer that drops off-line keeps its last real state, so coming back does not re-notify.
            if p.state == .offline || p.state == .unknown { continue }
            let old = states[p.key].flatMap(PrinterState.init(rawValue:))
            states[p.key] = p.state.rawValue
            if let old, old != p.state, let title = message(old, p) { notify(p, title) }
        }
        defaults.set(states, forKey: storeKey)
    }

    private func message(_ old: PrinterState, _ p: PrinterStatus) -> String? {
        switch p.state {
        case .finished: return old.active ? "Print finished" : nil
        case .failed: return old.active ? "Print failed or was stopped" : nil
        case .paused: return old == .printing || old == .preparing ? "Print paused" : nil
        default: return nil
        }
    }

    private func notify(_ p: PrinterStatus, _ title: String) {
        guard settings.notifications else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(p.name): \(title)"
        let text = [p.file, p.alert ?? p.stage].compactMap { $0 }.joined(separator: " · ")
        content.body = text.isEmpty ? p.via : text
        content.sound = .default
        content.userInfo = [TransitionNotifier.printerKey: p.key]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: p.key, content: content, trigger: nil))
    }

    /// Asks once for permission to notify; iOS remembers the answer.
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
}
