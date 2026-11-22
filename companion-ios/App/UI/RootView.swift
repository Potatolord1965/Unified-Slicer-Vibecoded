import SwiftUI
import UnifiedCore

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        TabView(selection: $model.tab) {
            NavigationStack(path: $model.printersPath) {
                PrintersView()
                    .navigationDestination(for: PrinterRoute.self) { route in
                        switch route {
                        case .printer(let key): PrinterDetailView(key: key)
                        case .files(let key): PrinterFilesView(key: key)
                        case .history(let key): PrintHistoryView(key: key)
                        }
                    }
            }
            .tabItem { Label("Printers", systemImage: "printer") }
            .tag(Tab.printers)

            NavigationStack { ModelsView() }
                .tabItem { Label("Models", systemImage: "cube") }
                .tag(Tab.models)

            NavigationStack { AccountsView() }
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
                .tag(Tab.accounts)

            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(Studio.text)
        .sheet(item: $model.sheet) { sheet in
            Group {
                switch sheet {
                case .add(let root): AddFlow(root: root)
                case .send: SendView()
                }
            }
            .environmentObject(model)
            .environmentObject(settings)
            .preferredColorScheme(settings.theme.scheme)
            .tint(Studio.text)
        }
        .alert(model.alert ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        }
        .preferredColorScheme(settings.theme.scheme)
    }
}
