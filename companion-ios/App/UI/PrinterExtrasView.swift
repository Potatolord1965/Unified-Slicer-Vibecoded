import SwiftUI
import UnifiedCore

/// Loads a list once (and on Retry), with loading and error states.
struct ListScreen<Item, Row: View>: View {
    let title: String
    let empty: String
    let load: () async throws -> [Item]
    @ViewBuilder let row: (Item) -> Row
    @State var attempt = 0
    @State var items: [Item]?
    @State var error: String?

    var body: some View {
        Group {
            if let error {
                VStack(spacing: 8) {
                    Text(error).font(.subheadline).foregroundColor(Studio.bad).multilineTextAlignment(.center)
                    Button("Retry") { attempt += 1 }
                }
                .padding(24)
            } else if let items {
                if items.isEmpty {
                    Text(empty).foregroundColor(Studio.muted)
                } else {
                    List {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in row(item) }
                            .listRowBackground(Studio.panel)
                    }
                    .scrollContentBackground(.hidden)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .studioBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: attempt) {
            error = nil
            items = nil
            do {
                items = try await load()
            } catch {
                if !Task.isCancelled { self.error = readable(error) }
            }
        }
    }
}

/// Files stored on the printer; tapping one asks before printing it.
struct PrinterFilesView: View {
    let key: String
    @EnvironmentObject var model: AppModel
    @State var chosen: PrinterFile?
    @State var result: String?

    var body: some View {
        if let p = model.printer(key) {
            let notReady = notReadyReason(p.state)
            ListScreen(title: "Files on \(p.name)", empty: "No print files on the printer.", load: { try await model.files(p) }) { (f: PrinterFile) in
                Button { chosen = f } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.name).foregroundColor(Studio.text).lineLimit(2)
                        let meta = [f.sizeBytes.map(formatSize), f.modifiedAt.map(formatDate)].compactMap { $0 }
                        if !meta.isEmpty { Text(meta.joined(separator: " · ")).font(.caption).foregroundColor(Studio.muted) }
                    }
                    .padding(.vertical, 4)
                }
            }
            .alert("Print this file?", isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } }), presenting: chosen) { f in
                if notReady == nil {
                    Button("Print") {
                        Task { result = await model.printFile(p, f) ?? "Print started" }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { f in
                Text(notReady ?? f.name)
            }
            .alert(result ?? "", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
                Button("OK") {
                    let started = result == "Print started"
                    result = nil
                    if started, !model.printersPath.isEmpty { model.printersPath.removeLast() }
                }
            }
        } else {
            Text("This printer is no longer on your accounts.").foregroundColor(Studio.muted)
        }
    }
}

/// Past prints, newest first.
struct PrintHistoryView: View {
    let key: String
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let p = model.printer(key) {
            ListScreen(title: "History of \(p.name)", empty: "No past prints yet.", load: { try await model.history(p) }) { (job: PastPrint) in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.name).foregroundColor(Studio.text).lineLimit(2)
                        let meta = [job.startedAt.map(formatDate), job.durationSeconds.map(formatDuration)].compactMap { $0 }
                        if !meta.isEmpty { Text(meta.joined(separator: " · ")).font(.caption).foregroundColor(Studio.muted) }
                    }
                    Spacer()
                    let word = job.note ?? label(job.state)
                    if !word.isEmpty { Text(word).font(.caption.weight(.medium)).foregroundColor(color(job.state)) }
                }
                .padding(.vertical, 4)
            }
        } else {
            Text("This printer is no longer on your accounts.").foregroundColor(Studio.muted)
        }
    }

    private func label(_ s: PrinterState) -> String {
        switch s {
        case .finished: return "Done"
        case .failed: return "Failed"
        case .printing: return "Printing"
        default: return ""
        }
    }

    private func color(_ s: PrinterState) -> Color {
        switch s {
        case .finished: return Studio.good
        case .failed: return Studio.bad
        default: return Studio.muted
        }
    }
}
