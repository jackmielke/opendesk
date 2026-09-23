import SwiftUI

/// Integration logos. Supabase and Airtable are drawn from their published SVG marks;
/// the rest use SF Symbols on the tool's brand color.
enum Integration: String, CaseIterable, Identifiable {
    case noco, supabase, airtable, grafana, metabase, gitlab, excalidraw
    var id: String { rawValue }

    var name: String {
        switch self {
        case .noco: "NocoDB"
        case .supabase: "Supabase"
        case .airtable: "Airtable"
        case .grafana: "Grafana"
        case .metabase: "Metabase"
        case .gitlab: "GitLab"
        case .excalidraw: "Excalidraw"
        }
    }

    var color: Color {
        switch self {
        case .noco: Brand.noco
        case .supabase: Brand.supabase
        case .airtable: Brand.airtable
        case .grafana: Brand.grafana
        case .metabase: Brand.metabase
        case .gitlab: Brand.gitlab
        case .excalidraw: Brand.excalidraw
        }
    }

    var symbol: String {
        switch self {
        case .noco: "tablecells.fill"
        case .grafana: "chart.xyaxis.line"
        case .metabase: "chart.pie.fill"
        case .gitlab: "chevron.left.forwardslash.chevron.right"
        case .excalidraw: "scribble.variable"
        default: "square"
        }
    }
}

struct BrandMark: View {
    let kind: Integration
    var size: CGFloat = 28

    var body: some View {
        switch kind {
        case .supabase:
            ZStack {
                SVGShape(path: SVGShape.supabaseA, viewBox: CGSize(width: 109, height: 113))
                    .fill(LinearGradient(colors: [Color(hex: "#249361"), Color(hex: "#3ECF8E")], startPoint: .bottomLeading, endPoint: .topTrailing))
                SVGShape(path: SVGShape.supabaseB, viewBox: CGSize(width: 109, height: 113)).fill(Color(hex: "#3ECF8E"))
            }
            .frame(width: size, height: size)
        case .airtable:
            ZStack {
                SVGShape(path: SVGShape.airtableTop, viewBox: CGSize(width: 200, height: 170)).fill(Color(hex: "#FFBF00"))
                SVGShape(path: SVGShape.airtableRight, viewBox: CGSize(width: 200, height: 170)).fill(Color(hex: "#26B5F8"))
                SVGShape(path: SVGShape.airtableLeft, viewBox: CGSize(width: 200, height: 170)).fill(Color(hex: "#ED3049"))
            }
            .frame(width: size, height: size * 0.85)
        default:
            Image(systemName: kind.symbol)
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(kind.color)
                .frame(width: size, height: size)
        }
    }
}

/// Minimal SVG path renderer: absolute M, L, H, V, C, Z. Enough for simple logo marks.
struct SVGShape: Shape {
    let path: String
    let viewBox: CGSize

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let dx = rect.minX + (rect.width - viewBox.width * scale) / 2
        let dy = rect.minY + (rect.height - viewBox.height * scale) / 2
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: dx + x * scale, y: dy + y * scale) }

        var p = Path()
        var tokens: [String] = []
        var cur = ""
        for ch in path {
            if ch.isLetter {
                if !cur.isEmpty { tokens.append(cur); cur = "" }
                tokens.append(String(ch))
            } else if ch == "," || ch == " " || ch == "\n" {
                if !cur.isEmpty { tokens.append(cur); cur = "" }
            } else if ch == "-" && !cur.isEmpty && !cur.hasSuffix("e") {
                tokens.append(cur); cur = "-"
            } else { cur.append(ch) }
        }
        if !cur.isEmpty { tokens.append(cur) }

        var i = 0, cmd = "M", last = CGPoint.zero
        func num() -> Double { defer { i += 1 }; return Double(tokens[i]) ?? 0 }
        while i < tokens.count {
            if let c = tokens[i].first, c.isLetter { cmd = tokens[i]; i += 1; if cmd == "Z" { p.closeSubpath(); continue } }
            guard i < tokens.count else { break }
            switch cmd {
            case "M": last = pt(num(), num()); p.move(to: last); cmd = "L"
            case "L": last = pt(num(), num()); p.addLine(to: last)
            case "H": let x = num(); last = CGPoint(x: dx + x * scale, y: last.y); p.addLine(to: last)
            case "V": let y = num(); last = CGPoint(x: last.x, y: dy + y * scale); p.addLine(to: last)
            case "C":
                let c1 = pt(num(), num()), c2 = pt(num(), num())
                last = pt(num(), num())
                p.addCurve(to: last, control1: c1, control2: c2)
            default: i += 1
            }
        }
        return p
    }

    static let supabaseA = "M63.7076 110.284C60.8481 113.885 55.0502 111.912 54.9813 107.314L53.9738 40.0627L99.1935 40.0627C107.384 40.0627 111.952 49.5228 106.859 55.9374L63.7076 110.284Z"
    static let supabaseB = "M45.317 2.07103C48.1765 -1.53037 53.9745 0.442937 54.0434 5.041L54.4849 72.2922H9.83113C1.64038 72.2922 -2.92775 62.8321 2.1655 56.4175L45.317 2.07103Z"
    static let airtableTop = "M90.0389 12.3675L24.0799 39.6605C20.4119 41.1785 20.4499 46.3885 24.1409 47.8515L90.3759 74.1175C96.1959 76.4255 102.6769 76.4255 108.4959 74.1175L174.7319 47.8515C178.4219 46.3885 178.4609 41.1785 174.7919 39.6605L108.8339 12.3675C102.8159 9.8775 96.0559 9.8775 90.0389 12.3675Z"
    static let airtableRight = "M105.3122 88.4608L105.3122 154.0768C105.3122 157.1978 108.4592 159.3348 111.3602 158.1848L185.1662 129.5368C186.8512 128.8688 187.9562 127.2408 187.9562 125.4288L187.9562 59.8128C187.9562 56.6918 184.8092 54.5548 181.9082 55.7048L108.1022 84.3528C106.4182 85.0208 105.3122 86.6488 105.3122 88.4608Z"
    static let airtableLeft = "M88.0781 91.8464L66.1741 102.4224L63.9501 103.4974L17.7121 125.6524C14.7811 127.0664 11.0401 124.9304 11.0401 121.6744L11.0401 60.0884C11.0401 58.9104 11.6441 57.8934 12.4541 57.1274C12.7921 56.7884 13.1751 56.5094 13.5731 56.2884C14.6781 55.6254 16.2541 55.4484 17.5941 55.9784L87.7101 83.7594C91.2741 85.1734 91.5541 90.1674 88.0781 91.8464Z"
}
