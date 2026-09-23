import SwiftUI

/// Airtable-style grid: a frozen first column, typed headers, compact cells, colored chips,
/// and a two-axis scroll, cleaner than a web spreadsheet on a phone.
struct GridView: View {
    let model: TableModel
    let rows: [NocoRecord]
    let open: (NocoRecord) -> Void

    private let rowH: CGFloat = 44
    private let firstW: CGFloat = 150

    private var cols: [NocoColumn] {
        model.visibleColumns.filter { $0.id != model.primary?.id }
    }

    private func width(_ c: NocoColumn) -> CGFloat {
        switch c.uidt {
        case "Checkbox", "Rating": 90
        case "Number", "Currency", "Decimal", "Percent", "Date": 110
        case "SingleSelect", "MultiSelect": 140
        case "LongText": 220
        case "Email", "URL": 190
        default: 150
        }
    }

    var body: some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                // Frozen primary column
                VStack(spacing: 0) {
                    header(model.primary?.title ?? "Name", icon: model.primary?.icon ?? "textformat", width: firstW)
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                        HStack(spacing: 8) {
                            Text("\(i + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 18, alignment: .trailing)
                            Text(model.primary.flatMap { r[$0.title]?.display }.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled")
                                .font(.subheadline.weight(.medium)).lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 10)
                        .frame(width: firstW, height: rowH)
                        .background(i % 2 == 0 ? Color.clear : Color.white.opacity(0.025))
                        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
                        .contentShape(Rectangle())
                        .onTapGesture { open(r) }
                    }
                }
                .background(Color(white: 0.07))
                .overlay(alignment: .trailing) { Rectangle().fill(Brand.stroke).frame(width: 1) }
                .zIndex(1)

                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) { ForEach(cols) { header($0.title, icon: $0.icon, width: width($0)) } }
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                            HStack(spacing: 0) {
                                ForEach(cols) { c in
                                    cell(c, r[c.title])
                                        .padding(.horizontal, 10)
                                        .frame(width: width(c), height: rowH, alignment: .leading)
                                        .overlay(alignment: .trailing) { Rectangle().fill(Brand.stroke).frame(width: 0.5) }
                                }
                            }
                            .background(i % 2 == 0 ? Color.clear : Color.white.opacity(0.025))
                            .overlay(alignment: .bottom) { Divider().opacity(0.5) }
                            .contentShape(Rectangle())
                            .onTapGesture { open(r) }
                        }
                    }
                }
            }
            .padding(.bottom, 90)
        }
    }

    private func header(_ title: String, icon: String, width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption2).foregroundStyle(.secondary)
            Text(title).font(.caption.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: 36)
        .background(Color(white: 0.11))
        .overlay(alignment: .bottom) { Rectangle().fill(Brand.stroke).frame(height: 1) }
        .overlay(alignment: .trailing) { Rectangle().fill(Brand.stroke).frame(width: 0.5) }
    }

    @ViewBuilder
    private func cell(_ c: NocoColumn, _ v: JSONValue?) -> some View {
        let value = v ?? .null
        switch c.uidt {
        case "SingleSelect":
            if let s = value.string, !s.isEmpty { Chip(text: s, color: vivid(c.color(for: s))) }
        case "MultiSelect":
            HStack(spacing: 4) {
                ForEach((value.string ?? "").split(separator: ",").prefix(3).map(String.init), id: \.self) { Chip(text: $0, color: vivid(c.color(for: $0))) }
            }
        case "Checkbox":
            Image(systemName: value.bool ? "checkmark.square.fill" : "square").foregroundStyle(value.bool ? Brand.ai : Color.secondary.opacity(0.4))
        case "Rating":
            Text(String(repeating: "★", count: value.int ?? 0)).font(.caption).foregroundStyle(.yellow)
        case "Currency", "Number", "Decimal", "Percent":
            Text(FieldText.format(c, value)).font(.subheadline.monospacedDigit()).frame(maxWidth: .infinity, alignment: .trailing)
        case "Email", "URL":
            Text(value.display).font(.subheadline).foregroundStyle(Brand.metabase).lineLimit(1)
        default:
            Text(FieldText.format(c, value)).font(.subheadline).foregroundStyle(c.uidt == "LongText" ? .secondary : .primary).lineLimit(1)
        }
    }
}
