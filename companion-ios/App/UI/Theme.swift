import SwiftUI
import UIKit
import UnifiedCore

extension Color {
    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }

    /// A colour that follows light and dark mode.
    static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        })
    }

    /// "#RRGGBB", or nil when malformed.
    init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(rgb: v)
    }
}

/// The desktop app's "Monochrome Studio" palette; the printer's brand colour is the accent.
enum Studio {
    static let bg = Color.dynamic(dark: 0x0F0F11, light: 0xF6F6F7)
    static let panel = Color.dynamic(dark: 0x17171A, light: 0xFFFFFF)
    static let hairline = Color.dynamic(dark: 0x2A2A2F, light: 0xE2E2E5)
    static let muted = Color.dynamic(dark: 0x9A9AA0, light: 0x66666C)
    static let text = Color.dynamic(dark: 0xEDEDEF, light: 0x121214)
    static let good = Color.dynamic(dark: 0x3DD68C, light: 0x1F9D57)
    static let warn = Color.dynamic(dark: 0xF5B83D, light: 0xB7791F)
    static let bad = Color.dynamic(dark: 0xE5484D, light: 0xD13438)
    /// The accent when no printer is in view.
    static let neutral = Color(rgb: 0x767676)
}

extension Brand {
    var color: Color { Color(rgb: accent) }
}

extension Font {
    /// Figures that don't jiggle as they change.
    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}
