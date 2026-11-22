import SwiftUI
import UnifiedCore

func stateColor(_ state: PrinterState, _ accent: Color) -> Color {
    switch state {
    case .printing, .preparing: return accent
    case .paused: return Studio.warn
    case .finished: return Studio.good
    case .failed: return Studio.bad
    case .idle: return Studio.text.opacity(0.75)
    case .offline, .unknown: return Studio.muted
    }
}

struct StateBadge: View {
    let state: PrinterState
    let accent: Color

    var body: some View {
        let c = stateColor(state, accent)
        HStack(spacing: 6) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text(state.label).font(.caption.weight(.medium)).foregroundColor(c)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(c.opacity(0.14)))
    }
}

/// A rounded card on the panel colour.
struct Panel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Studio.panel)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Studio.hairline, lineWidth: 1))
    }
}

struct AccentProgress: View {
    let progress: Int
    let accent: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(accent.opacity(0.16))
                Capsule().fill(accent).frame(width: geo.size.width * CGFloat(min(max(progress, 0), 100)) / 100)
            }
        }
        .frame(height: 6)
    }
}

struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundColor(Studio.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 20)
            .padding(.bottom, 8)
    }
}

private struct Meta: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption).lineLimit(1)
        }
        .foregroundColor(Studio.muted)
    }
}

struct PrinterCard: View {
    let p: PrinterStatus

    var body: some View {
        let accent = p.brand.color
        Panel {
            HStack(spacing: 0) {
                Rectangle().fill(accent).frame(width: 4)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(.headline).foregroundColor(Studio.text).lineLimit(1)
                            Text([p.model.isEmpty ? p.brand.label : p.model, p.via].joined(separator: " · "))
                                .font(.caption).foregroundColor(Studio.muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        StateBadge(state: p.state, accent: accent)
                    }
                    if p.state.active {
                        HStack(alignment: .lastTextBaseline) {
                            Text(p.file ?? p.stage ?? "").font(.subheadline).foregroundColor(Studio.text).lineLimit(1)
                            Spacer(minLength: 8)
                            if let progress = p.progress { Text("\(progress)%").font(.number(17)).foregroundColor(Studio.text) }
                        }
                        .padding(.top, 12)
                        AccentProgress(progress: p.progress ?? 0, accent: accent).padding(.top, 8)
                        HStack(spacing: 14) {
                            if let r = p.remainingSeconds { Meta(icon: "clock", text: "\(formatDuration(r)) left") }
                            if let layer = p.layer, let total = p.totalLayers { Meta(icon: "square.3.layers.3d", text: "\(layer)/\(total)") }
                            if let stage = p.stage, p.file != nil { Text(stage).font(.caption).foregroundColor(Studio.muted).lineLimit(1) }
                        }
                        .padding(.top, 8)
                    } else {
                        HStack(spacing: 14) {
                            if p.nozzle != nil { Text("Nozzle \(formatTemp(p.nozzle))").font(.caption).foregroundColor(Studio.muted) }
                            if p.bed != nil { Text("Bed \(formatTemp(p.bed))").font(.caption).foregroundColor(Studio.muted) }
                            if let alert = p.alert { Meta(icon: "exclamationmark.triangle", text: alert) }
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 16)
                .padding(.vertical, 14)
            }
        }
    }
}

struct LogoMark: View {
    var size: CGFloat = 22

    var body: some View {
        Image("Logo").resizable().scaledToFit().frame(width: size, height: size)
    }
}

/// A full-width button filled with `color`.
struct FilledButton: View {
    let title: String
    var color: Color = Studio.text
    var busy = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(busy ? 0 : 1)
                if busy { ProgressView().tint(.white) }
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(FilledStyle(color: color))
        .disabled(busy || !enabled)
    }
}

struct FilledStyle: ButtonStyle {
    let color: Color
    @Environment(\.isEnabled) var enabled
    @Environment(\.colorScheme) var scheme

    func makeBody(configuration: Configuration) -> some View {
        // The neutral text colour inverts in dark mode, so its label must too.
        let label: Color = color == Studio.text ? (scheme == .dark ? .black : .white) : .white
        configuration.label
            .foregroundColor(label)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

/// A full-width outlined button.
struct OutlineButton: View {
    let title: String
    var color: Color = Studio.text
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(OutlineStyle(color: color))
        .disabled(!enabled)
    }
}

struct OutlineStyle: ButtonStyle {
    let color: Color
    @Environment(\.isEnabled) var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(color)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Studio.hairline, lineWidth: 1))
            .contentShape(Rectangle())
            .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
    }
}

/// A row that opens something, inside a panel.
struct LinkRow: View {
    let icon: String
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundColor(Studio.muted).frame(width: 22)
                Text(text).foregroundColor(Studio.text)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundColor(Studio.muted)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Studio.hairline).frame(height: 1) }
}

extension View {
    /// The studio background behind a whole screen.
    func studioBackground() -> some View {
        background(Studio.bg.ignoresSafeArea())
    }
}
