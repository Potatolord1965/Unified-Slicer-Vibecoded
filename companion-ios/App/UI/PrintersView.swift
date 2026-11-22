import SwiftUI
import UnifiedCore

private func order(_ s: PrinterState) -> Int {
    switch s {
    case .printing, .preparing, .paused: return 0
    case .failed: return 1
    case .finished: return 2
    case .idle: return 3
    case .unknown: return 4
    case .offline: return 5
    }
}

struct PrintersView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.accounts.isEmpty {
                EmptyState()
            } else {
                list
            }
        }
        .studioBackground()
        .homeToolbar()
    }

    private var list: some View {
        let snapshot = model.snapshot
        let printers = (snapshot?.printers ?? []).sorted {
            (order($0.state), $0.name.lowercased()) < (order($1.state), $1.name.lowercased())
        }
        let problems = (snapshot?.problems.values.map { $0 } ?? []).sorted { $0.accountId < $1.accountId }
        let active = printers.filter { $0.state.active }.count
        let online = printers.filter { $0.state != .offline }.count
        let headline: String
        if snapshot == nil {
            headline = "Connecting…"
        } else if active > 0 {
            headline = active == 1 ? "1 printer working" : "\(active) printers working"
        } else {
            headline = "All quiet"
        }
        return ScrollView {
            LazyVStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.title2.weight(.semibold))
                    if let snapshot {
                        TimelineView(.periodic(from: .now, by: 5)) { _ in
                            Text("\(online) of \(printers.count) online · updated \(formatAgo(snapshot.at))")
                                .font(.caption).foregroundColor(Studio.muted)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .padding(.bottom, 6)

                ForEach(problems, id: \.accountId) { pr in problemPanel(pr) }
                ForEach(printers) { p in
                    Button { model.printersPath.append(.printer(p.key)) } label: { PrinterCard(p: p) }
                        .buttonStyle(.plain)
                }
                if snapshot != nil && printers.isEmpty && problems.isEmpty {
                    Text("No printers found on your accounts yet.").foregroundColor(Studio.muted).padding(.top, 24)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .refreshable { await model.refresh() }
    }

    private func problemPanel(_ pr: AccountProblem) -> some View {
        let name = model.accounts.first { $0.id == pr.accountId }.map { "\($0.kindLabel) (\($0.label))" } ?? "Account"
        return Button { model.tab = .accounts } label: {
            Panel {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.circle").foregroundColor(Studio.warn)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.subheadline).foregroundColor(Studio.text)
                        Text(pr.signInExpired ? "Sign-in expired. Tap to sign in again." : pr.message)
                            .font(.caption).foregroundColor(Studio.muted).lineLimit(2)
                    }
                }
                .padding(14)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct EmptyState: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            LogoMark(size: 72)
            Text("All your printers, one place").font(.title3.weight(.semibold)).multilineTextAlignment(.center).padding(.top, 24)
            Text("Sign in to Bambu Lab, Elegoo, Creality or Markforged, or add a printer on your network.")
                .font(.subheadline).foregroundColor(Studio.muted).multilineTextAlignment(.center).padding(.top, 8)
            FilledButton(title: "Add printer or account") { model.sheet = .add(nil) }
                .frame(maxWidth: 320)
                .padding(.top, 24)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HomeToolbar: ViewModifier {
    @EnvironmentObject var model: AppModel

    func body(content: Content) -> some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 10) {
                        LogoMark()
                        Text("Unified").font(.title3.weight(.semibold))
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { model.sheet = .add(nil) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add printer or account")
                }
            }
    }
}

extension View {
    /// The logo and the add button, on each tab's first screen.
    func homeToolbar() -> some View { modifier(HomeToolbar()) }
}
