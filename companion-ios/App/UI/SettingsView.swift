import SwiftUI
import UnifiedCore

private let sourceURL = URL(string: "https://github.com/Potatolord1965/Unified-Slicer-Vibecoded/tree/main/companion-ios")!
private let privacyURL = URL(string: "https://github.com/Potatolord1965/Unified-Slicer-Vibecoded/blob/main/PRIVACY.md")!

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @Environment(\.openURL) var openURL

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings").font(.title2.weight(.semibold)).padding(.top, 8)

                SectionLabel("Appearance")
                HStack(spacing: 8) {
                    ForEach(ThemeMode.allCases, id: \.self) { m in
                        Chip(text: m.label, selected: settings.theme == m, accent: Studio.neutral) { settings.theme = m }
                    }
                }

                SectionLabel("Live view")
                Text("Refresh every").font(.subheadline)
                HStack(spacing: 8) {
                    ForEach([5, 10, 30, 60], id: \.self) { s in
                        Chip(text: "\(s)s", selected: settings.refreshSeconds == s, accent: Studio.neutral) { settings.refreshSeconds = s }
                    }
                }
                .padding(.top, 6)

                SectionLabel("Notifications")
                toggle("Print finished, failed or paused", "Posts a notification when a print changes state.", $settings.notifications)
                    .onChange(of: settings.notifications) { on in if on { TransitionNotifier.requestPermission() } }
                toggle(
                    "Check while the app is closed",
                    "iOS decides when, usually every so often while the phone is in use. Turn off to save battery; you then only hear about prints while the app is open.",
                    $settings.backgroundChecks
                )
                .onChange(of: settings.backgroundChecks) { _ in model.scheduleBackgroundCheck() }

                SectionLabel("About")
                Text("Unified Monitor \(version)").font(.subheadline)
                Text("Companion to Unified Slicer. Watches Bambu Lab, Elegoo, Creality and Markforged printers plus Klipper, OctoPrint and PrusaLink on your network, and sends sliced files to Elegoo, Creality and network printers.")
                    .font(.caption).foregroundColor(Studio.muted).padding(.top, 4)
                Text("Unofficial free software, provided as is, with no warranty. Not affiliated with or endorsed by Bambu Lab, Elegoo, Creality, Markforged or Snapmaker; their names and trademarks belong to their owners. Cloud features are unofficial and used at your own risk. Never leave a printer unattended.")
                    .font(.caption).foregroundColor(Studio.muted).padding(.top, 8)
                HStack(spacing: 20) {
                    Button("Source code") { openURL(sourceURL) }
                    Button("Privacy") { openURL(privacyURL) }
                    NavigationLink("Licenses") { LicensesView() }
                }
                .font(.subheadline)
                .padding(.top, 12)
            }
            .padding(16)
        }
        .studioBackground()
        .homeToolbar()
    }

    private func toggle(_ title: String, _ subtitle: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle).font(.caption).foregroundColor(Studio.muted)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct LicensesView: View {
    var body: some View {
        let text = Bundle.main.url(forResource: "open_source_licenses", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        ScrollView {
            Text(text).font(.caption.monospaced()).textSelection(.enabled).padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .studioBackground()
        .navigationTitle("Open-source licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}
