import Foundation
import UnifiedCore

func formatDuration(_ seconds: Int64) -> String {
    let m = (seconds + 59) / 60
    if m < 60 { return "\(m)m" }
    if m < 60 * 24 { return "\(m / 60)h \(m % 60)m" }
    return "\(m / (60 * 24))d \((m / 60) % 24)h"
}

func formatAgo(_ at: Date, now: Date = Date()) -> String {
    let s = Int64(now.timeIntervalSince(at))
    if s < 10 { return "just now" }
    if s < 60 { return "\(s)s ago" }
    if s < 3600 { return "\(s / 60) min ago" }
    if s < 86400 { return "\(s / 3600) h ago" }
    return "\(s / 86400) d ago"
}

func formatTemp(_ t: Temperature?) -> String {
    guard let t else { return "–" }
    let cur = "\(Int(t.current.rounded()))°"
    guard let target = t.target else { return cur }
    return "\(cur) / \(Int(target.rounded()))°"
}

func etaClock(_ remainingSeconds: Int64, now: Date = Date()) -> String {
    let f = DateFormatter()
    f.dateStyle = .none
    f.timeStyle = .short
    return f.string(from: now.addingTimeInterval(TimeInterval(remainingSeconds)))
}

func formatSize(_ bytes: Int64) -> String {
    if bytes >= 1 << 20 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
    if bytes >= 1 << 10 { return "\(bytes >> 10) KB" }
    return "\(bytes) B"
}

func formatDate(_ at: Date) -> String {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f.string(from: at)
}

/// Why a printer in `state` takes no new print, or nil when it takes one.
func notReadyReason(_ state: PrinterState) -> String? {
    if state.ready { return nil }
    if state.active { return "The printer is busy with another print." }
    if state == .offline { return "The printer is offline." }
    return "The printer's state isn't known yet, so it might be printing."
}
