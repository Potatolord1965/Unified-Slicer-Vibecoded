import SwiftUI
import UnifiedCore

private func sizeText(_ bytes: Int64) -> String {
    bytes >= 1 << 20 ? String(format: "%.1f MB", Double(bytes) / 1_048_576) : "\((bytes + 1023) / 1024) KB"
}

/// Pick a printer for a printer-ready file, then watch the upload and start.
struct SendView: View {
    @EnvironmentObject var model: AppModel
    @State var selected: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let send = model.send {
                        progress(send)
                    } else if let job = model.pendingFile {
                        choice(job)
                    } else {
                        Hint("No file selected.")
                    }
                }
                .padding(16)
            }
            .studioBackground()
            .navigationTitle("Send to printer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if model.send?.done == true { model.closeSend() } else { model.sheet = nil }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func choice(_ job: PrintJob) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).font(.headline).lineLimit(2)
                Text(sizeText(fileSize(job.file))).font(.caption).foregroundColor(Studio.muted)
            }
            .padding(16)
        }
        let byId = Dictionary(model.accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let printers = model.snapshot?.printers ?? []
        let able = printers.filter { p in byId[p.accountId].map { printableBy($0, fileName: job.name) } == true }
        let ready = able.filter { $0.state.ready }
        let chosen = ready.first { $0.key == selected } ?? (ready.count == 1 ? ready[0] : nil)

        if able.isEmpty {
            Hint("None of your printers can take this file. The phone cannot slice, so the file has to be G-code made for the printer.")
        } else {
            SectionLabel("Printer").padding(.bottom, -12)
            ForEach(able) { p in
                let enabled = p.state.ready
                Button { selected = p.key } label: {
                    Panel {
                        HStack(spacing: 10) {
                            Image(systemName: chosen?.key == p.key ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(chosen?.key == p.key ? p.brand.color : Studio.muted)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).foregroundColor(Studio.text).lineLimit(1)
                                Text(p.via).font(.caption).foregroundColor(Studio.muted)
                            }
                            Spacer(minLength: 8)
                            StateBadge(state: p.state, accent: p.brand.color)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                    .opacity(enabled ? 1 : 0.5)
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
            }
        }
        // Brands that take no prints from this app: say why once.
        let reasons = model.accounts.filter { a in printers.contains { $0.accountId == a.id } }.compactMap(printBlockedReason)
        ForEach(Array(Set(reasons)).sorted(), id: \.self) { Hint($0) }

        if chosen != nil { Hint("The print starts right away. Make sure the bed is clear and the right filament is loaded.") }
        FilledButton(title: chosen.map { "Print on \($0.name)" } ?? "Print", color: chosen?.brand.color ?? Studio.neutral, enabled: chosen != nil) {
            if let chosen { model.startSend(chosen, job) }
        }
    }

    @ViewBuilder
    private func progress(_ send: SendState) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                Text(send.file).font(.headline).lineLimit(2)
                Text("to \(send.printer)").font(.caption).foregroundColor(Studio.muted)
                AccentProgress(progress: send.percent, accent: send.error != nil ? Studio.bad : send.done ? Studio.good : Studio.neutral)
                    .padding(.top, 16)
                Text(send.error ?? send.status)
                    .font(.subheadline)
                    .foregroundColor(send.error != nil ? Studio.bad : Studio.text)
                    .padding(.top, 10)
            }
            .padding(16)
        }
        if send.running {
            OutlineButton(title: "Cancel") { model.cancelSend() }
            Hint("You can close this screen; the send keeps going while the app is open.")
        } else if send.error != nil {
            FilledButton(title: "Try again") { model.clearSend() }
        } else {
            FilledButton(title: "Done") { model.closeSend() }
        }
    }
}
