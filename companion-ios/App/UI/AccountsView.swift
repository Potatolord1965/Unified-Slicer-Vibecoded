import SwiftUI
import UnifiedCore

struct AccountsView: View {
    @EnvironmentObject var model: AppModel
    @State var confirm: Account?

    var body: some View {
        let cloud = model.accounts.filter { $0.lan == nil }
        let lan = model.accounts.filter { $0.lan != nil }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Accounts & printers").font(.title2.weight(.semibold)).padding(.top, 8)
                Text("Sign-ins and access codes are stored in this phone's keychain only.")
                    .font(.caption).foregroundColor(Studio.muted).padding(.top, 2)
                if !cloud.isEmpty { SectionLabel("Cloud") }
                ForEach(cloud) { row($0) }
                if !lan.isEmpty { SectionLabel("Local network") }
                ForEach(lan) { row($0) }
                OutlineButton(title: "Scan computer code") { model.sheet = .add(.scan) }
                    .padding(.top, 20)
                Text("Signs in to every account Unified Slicer on your computer uses. Open Accounts there and click Sign in on phone.")
                    .font(.caption).foregroundColor(Studio.muted).padding(.top, 6)
                OutlineButton(title: "Add printer or account") { model.sheet = .add(nil) }
                    .padding(.top, 12)
            }
            .padding(16)
        }
        .studioBackground()
        .homeToolbar()
        .alert(Text("Remove \(confirm?.label ?? "")?"), isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { a in
            Button("Remove", role: .destructive) { model.removeAccount(a.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its printers disappear from the app. You can add it again any time.")
        }
    }

    private func row(_ a: Account) -> some View {
        let problem = model.snapshot?.problems[a.id]
        let count = model.snapshot?.printers.filter { $0.accountId == a.id }.count ?? 0
        let status: String
        if problem?.signInExpired == true {
            status = "Sign-in expired"
        } else if let problem {
            status = problem.message
        } else if a.lan != nil {
            status = a.kindLabel
        } else {
            status = "\(a.kindLabel) · " + (count == 1 ? "1 printer" : "\(count) printers")
        }
        return Panel {
            HStack(spacing: 14) {
                Circle().fill(a.brand.color).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.label).foregroundColor(Studio.text)
                    Text(status).font(.caption).foregroundColor(problem != nil ? Studio.warn : Studio.muted).lineLimit(2)
                }
                Spacer()
                Menu {
                    Button(a.lan != nil ? "Edit" : "Sign in again") { model.sheet = .add(AddRoute.edit(a)) }
                    Button("Remove", role: .destructive) { confirm = a }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 36, height: 36).contentShape(Rectangle())
                }
                .foregroundColor(Studio.muted)
                .accessibilityLabel("More")
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 12)
        }
        .padding(.bottom, 8)
    }
}
