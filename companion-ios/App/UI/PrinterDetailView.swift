import SwiftUI
import UnifiedCore

/// Runs one command at a time and keeps the last failure for the screen to show.
@MainActor
final class CommandRunner: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var error: String?

    func run(_ command: PrinterCommand, on p: PrinterStatus, _ model: AppModel) {
        if busy { return }
        busy = true
        error = nil
        Task {
            error = await model.control(p, command)
            busy = false
        }
    }
}

struct PrinterDetailView: View {
    let key: String
    @EnvironmentObject var model: AppModel
    @StateObject var commands = CommandRunner()
    @State var editing: Control?
    @State var tempText = ""
    @State var confirmStop = false

    var body: some View {
        Group {
            if let p = model.printer(key) {
                content(p)
            } else {
                Text("This printer is no longer on your accounts.")
                    .foregroundColor(Studio.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .studioBackground()
        .navigationTitle(model.printer(key)?.name ?? "Printer")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ p: PrinterStatus) -> some View {
        let accent = p.brand.color
        let account = model.account(of: p)
        let controls = account.map(controlsFor) ?? []
        let offline = p.state == .offline
        return ScrollView {
            VStack(spacing: 0) {
                StateBadge(state: p.state, accent: accent).padding(.top, 8)
                ring(p, accent).padding(.top, 20)
                if let file = p.file {
                    Text(file).font(.headline).multilineTextAlignment(.center).lineLimit(2).padding(.top, 16)
                }
                if let stage = p.stage { Text(stage).font(.subheadline).foregroundColor(accent).padding(.top, 2) }
                if let alert = p.alert { Text(alert).font(.subheadline).foregroundColor(Studio.bad).multilineTextAlignment(.center).padding(.top, 2) }
                Spacer().frame(height: 20)

                jobControls(p, controls, accent)
                if let account, hasCamera(account), !offline {
                    CameraPanel(printer: p, accent: accent).padding(.bottom, 10)
                }
                HStack(spacing: 10) {
                    tempTile("Nozzle", p.nozzle, controls.contains(.nozzleTemp) && !offline ? Control.nozzleTemp : nil)
                    tempTile("Bed", p.bed, controls.contains(.bedTemp) && !offline ? Control.bedTemp : nil)
                    if p.chamber != nil { tempTile("Chamber", p.chamber, nil) }
                }
                .padding(.bottom, 10)
                DeviceControls(p: p, controls: controls, accent: accent, commands: commands)
                FilamentPanel(slots: p.filament, accent: accent)
                MovePanel(p: p, controls: controls, accent: accent, commands: commands)
                if let account { moreLinks(p, account) }
                Panel {
                    VStack(spacing: 0) {
                        if let layer = p.layer, let total = p.totalLayers { infoRow("Layer", "\(layer) / \(total)") }
                        infoRow("Model", p.model.isEmpty ? p.brand.label : p.model)
                        infoRow("Connection", p.via)
                        infoRow("Serial / ID", p.deviceId)
                        infoRow("Updated", formatAgo(p.updatedAt), last: true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
                Spacer().frame(height: 24)
            }
            .padding(.horizontal, 16)
        }
        .refreshable { await model.refresh() }
        .alert(Text(editing == .nozzleTemp ? "Nozzle temperature" : "Bed temperature"), isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("°C", text: $tempText).keyboardType(.numberPad)
            Button("Set") {
                let limit = editing == .nozzleTemp ? 320 : 120
                if let v = Int(tempText), (0...limit).contains(v) { setTemp(p, v) }
                editing = nil
            }
            Button("Heater off") {
                setTemp(p, 0)
                editing = nil
            }
            Button("Cancel", role: .cancel) { editing = nil }
        } message: {
            Text("Target in °C (up to \(editing == .nozzleTemp ? 320 : 120))")
        }
        .alert("Stop this print?", isPresented: $confirmStop) {
            Button("Stop", role: .destructive) { commands.run(.stop, on: p, model) }
            Button("Keep printing", role: .cancel) {}
        } message: {
            Text("A stopped print cannot be resumed.")
        }
    }

    private func setTemp(_ p: PrinterStatus, _ celsius: Int) {
        commands.run(editing == .nozzleTemp ? .setNozzle(celsius) : .setBed(celsius), on: p, model)
    }

    private func ring(_ p: PrinterStatus, _ accent: Color) -> some View {
        let shown = p.progress != nil && (p.state.active || p.state == .finished)
        let fraction = shown ? CGFloat(min(max(p.progress ?? 0, 0), 100)) / 100 : 0
        return ZStack {
            Circle().stroke(accent.opacity(0.14), lineWidth: 12)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(stateColor(p.state, accent), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut, value: fraction)
            VStack(spacing: 2) {
                Text(shown ? "\(p.progress ?? 0)%" : p.state.label)
                    .font(.number(shown ? 44 : 28))
                    .foregroundColor(Studio.text)
                if let r = p.remainingSeconds {
                    Text("\(formatDuration(r)) left").font(.subheadline).foregroundColor(Studio.muted)
                    Text("done ~\(etaClock(r))").font(.caption).foregroundColor(Studio.muted)
                }
            }
        }
        .frame(width: 200, height: 200)
    }

    @ViewBuilder
    private func jobControls(_ p: PrinterStatus, _ controls: Set<Control>, _ accent: Color) -> some View {
        let paused = p.state == .paused
        let canToggle = paused ? controls.contains(.resume) : controls.contains(.pause) && p.state == .printing
        let canStop = controls.contains(.stop) && p.state.active
        if canToggle || canStop {
            HStack(spacing: 10) {
                if canToggle {
                    FilledButton(title: paused ? "Resume" : "Pause", color: accent, enabled: !commands.busy) {
                        commands.run(paused ? .resume : .pause, on: p, model)
                    }
                }
                if canStop {
                    OutlineButton(title: "Stop", color: Studio.bad, enabled: !commands.busy) { confirmStop = true }
                }
            }
            .padding(.bottom, 10)
        }
        if let error = commands.error {
            Text(error).font(.caption).foregroundColor(Studio.bad)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 10)
        }
    }

    private func tempTile(_ label: String, _ t: Temperature?, _ edit: Control?) -> some View {
        Button {
            guard let edit else { return }
            let current = edit == .nozzleTemp ? model.printer(key)?.nozzle?.target : model.printer(key)?.bed?.target
            tempText = current.map { String(Int($0)) } ?? ""
            editing = edit
        } label: {
            Panel {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label.uppercased()).font(.caption2.weight(.semibold)).foregroundColor(Studio.muted)
                    Text(t.map { "\(Int($0.current))°" } ?? "–").font(.number(22)).foregroundColor(Studio.text)
                    if let target = t?.target {
                        Text("target \(Int(target))°").font(.caption).foregroundColor(Studio.muted)
                    } else if edit != nil {
                        Text("tap to set").font(.caption).foregroundColor(Studio.muted)
                    }
                }
                .padding(14)
            }
        }
        .buttonStyle(.plain)
        .disabled(edit == nil)
    }

    @ViewBuilder
    private func moreLinks(_ p: PrinterStatus, _ account: Account) -> some View {
        let files = canBrowseFiles(account)
        let history = hasHistory(account)
        if files || history {
            Panel {
                VStack(spacing: 0) {
                    if files {
                        LinkRow(icon: "folder", text: "Files on the printer") { model.printersPath.append(.files(p.key)) }
                    }
                    if files && history { Hairline() }
                    if history {
                        LinkRow(icon: "clock.arrow.circlepath", text: "Print history") { model.printersPath.append(.history(p.key)) }
                    }
                }
            }
            .padding(.bottom, 10)
        }
    }

    private func infoRow(_ label: String, _ value: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).foregroundColor(Studio.muted)
                Spacer()
                Text(value).foregroundColor(Studio.text).lineLimit(1).truncationMode(.middle)
            }
            .font(.subheadline)
            .padding(.vertical, 10)
            if !last { Hairline() }
        }
    }
}

/// Chamber light and print speed, for printers that have them.
struct DeviceControls: View {
    let p: PrinterStatus
    let controls: Set<Control>
    let accent: Color
    @ObservedObject var commands: CommandRunner
    @EnvironmentObject var model: AppModel

    var body: some View {
        let light = controls.contains(.light) && p.state != .offline
        let speed = controls.contains(.speed) && p.state.active
        if light || speed {
            Panel {
                VStack(alignment: .leading, spacing: 8) {
                    if light {
                        Toggle("Light", isOn: Binding(get: { p.light == true }, set: { commands.run(.light($0), on: p, model) }))
                            .tint(accent)
                            .disabled(commands.busy)
                    }
                    if speed {
                        Text("Speed").font(.subheadline)
                        HStack(spacing: 6) {
                            ForEach(SpeedLevel.allCases, id: \.self) { level in
                                Chip(text: level.label, selected: p.speedLevel == level.rawValue, accent: accent) {
                                    commands.run(.speed(level), on: p, model)
                                }
                                .disabled(commands.busy)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .padding(.bottom, 10)
        }
    }
}

struct Chip: View {
    let text: String
    let selected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .foregroundColor(selected ? .white : Studio.text)
                .background(RoundedRectangle(cornerRadius: 8).fill(selected ? accent : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? accent : Studio.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// The loaded filament: one swatch per slot, the one feeding the nozzle outlined.
struct FilamentPanel: View {
    let slots: [FilamentSlot]
    let accent: Color

    var body: some View {
        if !slots.isEmpty {
            SectionLabel("Filament").padding(.top, -14)
            Panel {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64, maximum: 72), spacing: 10)], spacing: 10) {
                    ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in swatch(slot) }
                }
                .padding(12)
            }
            .padding(.bottom, 10)
        }
    }

    private func swatch(_ slot: FilamentSlot) -> some View {
        let fill = slot.color.flatMap { Color(hex: $0) }
        return VStack(spacing: 2) {
            Circle()
                .fill(slot.empty || fill == nil ? Color.clear : fill!)
                .overlay(Circle().stroke(Studio.muted.opacity(0.5), lineWidth: 1))
                .frame(width: 26, height: 26)
                .padding(.bottom, 2)
            Text(slot.label).font(.caption2).foregroundColor(Studio.muted)
            Text(slot.empty ? "–" : slot.type).font(.caption.weight(.medium)).lineLimit(1)
            if let remain = slot.remainPercent, !slot.empty {
                Text("\(remain)%").font(.caption2).foregroundColor(Studio.muted)
            }
        }
        .padding(.vertical, 8)
        .frame(width: 64)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(slot.active ? accent : Studio.hairline, lineWidth: slot.active ? 2 : 1))
    }
}

/// Home and step moves, for an idle printer. Collapsed until opened, so a stray tap moves nothing.
struct MovePanel: View {
    let p: PrinterStatus
    let controls: Set<Control>
    let accent: Color
    @ObservedObject var commands: CommandRunner
    @EnvironmentObject var model: AppModel
    @State var open = false
    @State var step = 10.0

    var body: some View {
        if controls.contains(.move) && p.state.ready {
            Panel {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Move").font(.subheadline)
                        Spacer()
                        Button(open ? "Hide" : "Show") { open.toggle() }.foregroundColor(accent)
                    }
                    if open {
                        HStack(spacing: 6) {
                            ForEach([0.1, 1.0, 10.0], id: \.self) { s in
                                Chip(text: s < 1 ? "\(s) mm" : "\(Int(s)) mm", selected: step == s, accent: accent) { step = s }
                            }
                        }
                        ForEach([Axis.x, .y, .z], id: \.self) { axis in
                            HStack(spacing: 8) {
                                Text(axis.rawValue.uppercased()).font(.headline).frame(width: 28, alignment: .leading)
                                OutlineButton(title: "−", enabled: !commands.busy) { commands.run(.move(axis, -step), on: p, model) }
                                OutlineButton(title: "+", enabled: !commands.busy) { commands.run(.move(axis, step), on: p, model) }
                            }
                        }
                        OutlineButton(title: "Home all axes", enabled: !commands.busy) { commands.run(.home, on: p, model) }
                        Text("Moves are relative. Home first after the printer was switched on.")
                            .font(.caption).foregroundColor(Studio.muted)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .padding(.bottom, 10)
        }
    }
}
