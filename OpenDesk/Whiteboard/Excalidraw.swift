import Foundation

/// Builds Excalidraw scenes (the open `.excalidraw` JSON format) from live data.
enum Excalidraw {
    struct Board: Identifiable, Codable, Hashable {
        var id: String
        var name: String
        var updated: Date
        var elements: JSONValue
    }

    private static var seed = 1
    private static func next() -> Int { seed += 1; return seed }

    static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, fill: String, stroke: String = "#1e1e1e", dashed: Bool = false) -> JSONValue {
        let n = next()
        return .object([
            "type": .string("rectangle"), "id": .string("r\(n)"),
            "x": .number(x), "y": .number(y), "width": .number(w), "height": .number(h),
            "strokeColor": .string(stroke), "backgroundColor": .string(fill), "fillStyle": .string("solid"),
            "strokeWidth": .number(1), "strokeStyle": .string(dashed ? "dashed" : "solid"),
            "roughness": .number(1), "opacity": .number(100), "angle": .number(0),
            "seed": .number(Double(n)), "version": .number(1), "versionNonce": .number(Double(n)),
            "isDeleted": .bool(false), "groupIds": .array([]), "boundElements": .null,
            "updated": .number(1), "link": .null, "locked": .bool(false),
            "roundness": .object(["type": .number(3)]), "frameId": .null,
        ])
    }

    static func text(_ s: String, _ x: Double, _ y: Double, size: Double = 16, color: String = "#1e1e1e", font: Int = 5) -> JSONValue {
        let n = next()
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        let w = Double(lines.map(\.count).max() ?? 1) * size * 0.56
        return .object([
            "type": .string("text"), "id": .string("t\(n)"),
            "x": .number(x), "y": .number(y), "width": .number(w), "height": .number(Double(lines.count) * size * 1.25),
            "text": .string(s), "originalText": .string(s), "fontSize": .number(size), "fontFamily": .number(Double(font)),
            "textAlign": .string("left"), "verticalAlign": .string("top"), "containerId": .null,
            "lineHeight": .number(1.25), "autoResize": .bool(true),
            "strokeColor": .string(color), "backgroundColor": .string("transparent"), "fillStyle": .string("solid"),
            "strokeWidth": .number(1), "strokeStyle": .string("solid"), "roughness": .number(1), "opacity": .number(100), "angle": .number(0),
            "seed": .number(Double(n)), "version": .number(1), "versionNonce": .number(Double(n)),
            "isDeleted": .bool(false), "groupIds": .array([]), "boundElements": .null,
            "updated": .number(1), "link": .null, "locked": .bool(false), "roundness": .null, "frameId": .null,
        ])
    }

    static let pastels = ["#a5d8ff", "#b2f2bb", "#ffec99", "#d0bfff", "#ffc9c9", "#99e9f2", "#ffd8a8", "#eebefa"]

    /// An entity map of every NocoDB base: one card per table, listing its columns and types.
    static func schemaMap(bases: [(NocoBase, [(NocoTable, [NocoColumn])])]) -> [JSONValue] {
        var out: [JSONValue] = []
        var y = 0.0
        for (bi, (base, tables)) in bases.enumerated() where !tables.isEmpty {
            out.append(text(base.title, 0, y, size: 36))
            y += 64
            var x = 0.0, rowMax = 0.0
            for (ti, (table, cols)) in tables.enumerated() {
                let visible = cols.filter(\.isVisible)
                let h = 52 + Double(visible.count) * 24 + 12
                if ti > 0 && ti % 3 == 0 { x = 0; y += rowMax + 40; rowMax = 0 }
                out.append(rect(x, y, 280, h, fill: "#ffffff"))
                out.append(rect(x, y, 280, 44, fill: pastels[(bi * 3 + ti) % pastels.count]))
                out.append(text(table.title, x + 14, y + 10, size: 22))
                for (ci, c) in visible.enumerated() {
                    let cy = y + 54 + Double(ci) * 24
                    out.append(text((c.isPrimary ? "★ " : "") + c.title, x + 14, cy, size: 15))
                    out.append(text(c.uidt, x + 170, cy + 1, size: 12, color: "#868e96", font: 3))
                }
                x += 320
                rowMax = max(rowMax, h)
            }
            y += rowMax + 90
        }
        return out
    }

    /// A planning wall: one lane per stage, one sticky note per row.
    static func pipelineWall(title: String, stageColumn: NocoColumn, primary: String, records: [NocoRecord], extra: (NocoRecord) -> String) -> [JSONValue] {
        var out: [JSONValue] = [text(title, 0, -80, size: 36)]
        for (i, opt) in stageColumn.options.enumerated() {
            let x = Double(i) * 260
            let items = records.filter { $0[stageColumn.title]?.string == opt.title }
            out.append(rect(x - 10, -20, 240, 60 + Double(max(items.count, 1)) * 108, fill: "transparent", stroke: "#adb5bd", dashed: true))
            out.append(text("\(opt.title) · \(items.count)", x, -8, size: 22))
            for (j, r) in items.prefix(12).enumerated() {
                let y = 36 + Double(j) * 108
                let fill = opt.color ?? pastels[i % pastels.count]
                out.append(rect(x, y, 220, 96, fill: fill))
                let name = r[primary]?.display ?? ""
                out.append(text(wrap(name, 22), x + 10, y + 8, size: 16))
                out.append(text(extra(r), x + 10, y + 64, size: 13, color: "#495057"))
            }
        }
        return out
    }

    private static func wrap(_ s: String, _ n: Int) -> String {
        var lines: [String] = [], cur = ""
        for w in s.split(separator: " ") {
            if cur.count + w.count + 1 > n, !cur.isEmpty { lines.append(cur); cur = "" }
            cur += (cur.isEmpty ? "" : " ") + w
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines.prefix(2).joined(separator: "\n")
    }

    /// A standard `.excalidraw` file, openable on excalidraw.com or in any Excalidraw app.
    static func file(_ elements: JSONValue) -> Data {
        let doc: JSONValue = .object([
            "type": .string("excalidraw"), "version": .number(2), "source": .string("https://github.com/jackmielke/opendesk"),
            "elements": elements, "appState": .object(["viewBackgroundColor": .string("#ffffff")]), "files": .object([:]),
        ])
        return (try? JSONEncoder().encode(doc)) ?? Data()
    }
}

/// Boards live as JSON files in the app's Documents folder.
enum BoardStore {
    private static var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("boards", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func all() -> [Excalidraw.Board] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        return files.compactMap { try? dec.decode(Excalidraw.Board.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updated > $1.updated }
    }

    static func save(_ b: Excalidraw.Board) {
        var b = b
        b.updated = Date()
        if let d = try? JSONEncoder().encode(b) { try? d.write(to: dir.appendingPathComponent("\(b.id).json"), options: .atomic) }
    }

    static func delete(_ b: Excalidraw.Board) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(b.id).json"))
    }

    static func exportURL(_ b: Excalidraw.Board) -> URL {
        let safe = b.name.replacingOccurrences(of: "/", with: "-")
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).excalidraw")
        try? Excalidraw.file(b.elements).write(to: u, options: .atomic)
        return u
    }
}
