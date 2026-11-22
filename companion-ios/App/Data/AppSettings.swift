import SwiftUI

enum ThemeMode: String, CaseIterable {
    case dark, light, system

    var label: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .system: return "System"
        }
    }

    var scheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}

/// Small user preferences. Dark is the default, as in the desktop app.
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var theme: ThemeMode { didSet { defaults.set(theme.rawValue, forKey: "theme") } }
    /// Notify when a print finishes, fails or pauses.
    @Published var notifications: Bool { didSet { defaults.set(notifications, forKey: "notifications") } }
    /// Let iOS check printers now and then while the app is closed (needed for notifications then).
    @Published var backgroundChecks: Bool { didSet { defaults.set(backgroundChecks, forKey: "background") } }
    @Published var refreshSeconds: Int { didSet { defaults.set(refreshSeconds, forKey: "refresh") } }

    init() {
        theme = ThemeMode(rawValue: defaults.string(forKey: "theme") ?? "") ?? .dark
        notifications = defaults.object(forKey: "notifications") as? Bool ?? true
        backgroundChecks = defaults.object(forKey: "background") as? Bool ?? true
        let refresh = defaults.integer(forKey: "refresh")
        refreshSeconds = refresh > 0 ? refresh : 10
    }
}
