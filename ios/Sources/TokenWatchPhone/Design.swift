import SwiftUI
import TokenWatchCore

enum Palette {
    static let paper = Color.white
    static let card = Color.white
    static let ink = Color.black
    static let muted = Color(white: 0.42)
    static let line = Color(white: 0.90)
    static let green = Color(red: 0.0, green: 0.55, blue: 0.31)
    static let rust = Color(red: 0.85, green: 0.19, blue: 0.10)
    static let accent = Color(red: 0.10, green: 0.29, blue: 0.98)
    static let reset = Color(red: 0.87, green: 0.98, blue: 0.28)

    static func provider(_ name: String) -> Color {
        switch name {
        case "Claude": Color(red: 0.84, green: 0.20, blue: 0.06)
        case "Codex": accent
        case "Gemini": Color(red: 0.43, green: 0.16, blue: 0.92)
        case "Muse": Color(red: 0.81, green: 0.05, blue: 0.46)
        case "Z.ai": Color(red: 0.36, green: 0.48, blue: 0.0)
        case "AliCloud": Color(red: 0.68, green: 0.35, blue: 0.0)
        default: Color(red: 0.0, green: 0.48, blue: 0.48)
        }
    }
}

struct Eyebrow: View {
    let text: String
    var color: Color = Palette.muted
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .tracking(1)
            .foregroundStyle(color)
    }
}

struct WatchMark: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            Rectangle().fill(Palette.accent).frame(width: 5, height: 16)
            Rectangle().fill(Palette.provider("Claude")).frame(width: 5, height: 26)
            Rectangle().fill(Palette.reset).frame(width: 5, height: 21)
        }
        .frame(width: 21, height: 26)
        .accessibilityHidden(true)
    }
}

struct UsageTrack: View {
    let fraction: Double?
    let color: Color
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(color.opacity(0.12))
                if let fraction, fraction > 0 {
                    Rectangle().fill(color).frame(width: max(2, proxy.size.width * fraction))
                }
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

enum UsageText {
    static func percentage(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value > 0 && value < 1 { return "<1" }
        return value.formatted(.number.precision(.fractionLength(0)))
    }

    static func reset(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "Reset not reported" }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "Awaiting next reading" }
        let minutes = Int(ceil(seconds / 60))
        if minutes < 60 { return "Resets in \(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "Resets in \(hours)h \(minutes % 60)m" }
        return "Resets in \(hours / 24)d \(hours % 24)h"
    }
}
