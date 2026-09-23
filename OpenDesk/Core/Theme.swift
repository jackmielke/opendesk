import SwiftUI

enum Brand {
    static let noco = Color(red: 0.49, green: 0.44, blue: 0.97)
    static let grafana = Color(red: 0.96, green: 0.52, blue: 0.10)
    static let gitlab = Color(red: 0.99, green: 0.43, blue: 0.15)
    static let ai = Color(red: 0.36, green: 0.80, blue: 0.72)
    static let card = Color.white.opacity(0.06)
    static let stroke = Color.white.opacity(0.08)
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        if s.count == 6 {
            self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
        } else {
            self.init(white: 0.5)
        }
    }
}

struct CardBackground: ViewModifier {
    var padding: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Brand.stroke))
    }
}

extension View {
    func card(padding: CGFloat = 14) -> some View { modifier(CardBackground(padding: padding)) }
}

struct Chip: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.22), in: Capsule())
            .foregroundStyle(color)
    }
}

/// NocoDB's select colors are pastel for light mode; brighten them into something readable on dark.
func vivid(_ hex: String?) -> Color {
    guard let hex else { return .secondary }
    let base = Color(hex: hex)
    let ui = UIColor(base)
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    if s < 0.05 { return .secondary }
    return Color(hue: h, saturation: min(1, s * 2.6 + 0.25), brightness: 0.95)
}

struct ErrorCard: View {
    let message: String
    var retry: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Couldn't load", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.orange)
            Text(message).font(.footnote).foregroundStyle(.secondary)
            if let retry { Button("Retry", action: retry).buttonStyle(.bordered) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

extension Double {
    var compact: String {
        let a = abs(self)
        if a >= 1_000_000 { return String(format: "%.1fM", self / 1_000_000) }
        if a >= 10_000 { return String(format: "%.0fK", self / 1_000) }
        if a >= 1_000 { return String(format: "%.1fK", self / 1_000) }
        if a == rounded() { return String(Int(self)) }
        return String(format: a < 1 ? "%.3f" : "%.2f", self)
    }
    var currency: String { "$" + (self >= 10_000 ? compact : String(format: "%.0f", self)) }
}

func relativeDate(_ iso: String?) -> String {
    guard let iso else { return "" }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    guard let d else { return iso }
    return d.formatted(.relative(presentation: .named))
}

extension String {
    /// Inline-only Markdown can't render lists; turn list markers into bullets so they don't show as raw asterisks.
    var bulleted: String {
        split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let indent = line.prefix { $0 == " " }
            let rest = line.dropFirst(indent.count)
            if rest.hasPrefix("* ") || rest.hasPrefix("- ") { return indent + "• " + rest.dropFirst(2) }
            return String(line)
        }.joined(separator: "\n")
    }
}
