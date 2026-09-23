import SwiftUI
import WebKit

extension Brand {
    static let excalidraw = Color(red: 0.42, green: 0.40, blue: 0.93)
}

struct WhiteboardHomeView: View {
    @Environment(AppConfig.self) private var config
    @State private var boards: [Excalidraw.Board] = []
    @State private var open: Excalidraw.Board?
    @State private var building: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    generator("Map my database", "Every NocoDB base and table as an entity map", "square.grid.3x3.topleft.filled") { try await schemaBoard() }
                    generator("Pipeline wall", "Events as sticky notes, one lane per stage", "rectangle.split.3x1") { try await pipelineBoard() }
                    generator("Blank board", "Sketch anything, open source Excalidraw", "scribble.variable") {
                        Excalidraw.Board(id: UUID().uuidString, name: "Untitled board", updated: Date(), elements: .array([]))
                    }
                } header: { Text("Start from your data") } footer: {
                    if let error { Text(error).foregroundStyle(.orange) }
                }
                if !boards.isEmpty {
                    Section("Your boards") {
                        ForEach(boards) { b in
                            Button { open = b } label: {
                                HStack {
                                    Image(systemName: "scribble").foregroundStyle(Brand.excalidraw)
                                    VStack(alignment: .leading) {
                                        Text(b.name).foregroundStyle(.primary)
                                        Text("\(b.elements.array.count) shapes · \(b.updated.formatted(.relative(presentation: .named)))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .swipeActions { Button("Delete", role: .destructive) { BoardStore.delete(b); reload() } }
                        }
                    }
                }
            }
            .navigationTitle("Whiteboard")
            .onAppear(perform: reload)
            .fullScreenCover(item: $open, onDismiss: reload) { BoardEditor(board: $0) }
        }
    }

    private func generator(_ title: String, _ sub: String, _ icon: String, make: @escaping () async throws -> Excalidraw.Board?) -> some View {
        Button {
            building = title
            Task {
                do {
                    if let b = try await make() { BoardStore.save(b); open = b }
                    error = nil
                } catch { self.error = error.localizedDescription }
                building = nil
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title3).foregroundStyle(Brand.excalidraw).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(sub).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if building == title { ProgressView() }
            }
        }
        .disabled(building != nil)
    }

    private func reload() { boards = BoardStore.all() }

    private func schemaBoard() async throws -> Excalidraw.Board {
        let noco = config.noco
        var result: [(NocoBase, [(NocoTable, [NocoColumn])])] = []
        for b in try await noco.bases() {
            var tables: [(NocoTable, [NocoColumn])] = []
            for t in try await noco.tables(baseId: b.id) { tables.append((t, try await noco.columns(tableId: t.id))) }
            result.append((b, tables))
        }
        result.sort { $0.1.count > $1.1.count }
        return Excalidraw.Board(id: UUID().uuidString, name: "Database map", updated: Date(),
                                elements: .array(Excalidraw.schemaMap(bases: result)))
    }

    private func pipelineBoard() async throws -> Excalidraw.Board? {
        let noco = config.noco
        for b in try await noco.bases() {
            for t in try await noco.tables(baseId: b.id) {
                let cols = try await noco.columns(tableId: t.id)
                guard let stage = cols.first(where: { $0.isSelect && ["stage", "status"].contains($0.title.lowercased()) }) else { continue }
                let rows = try await noco.allRecords(tableId: t.id)
                let primary = cols.first(where: \.isPrimary)?.title ?? cols.first(where: \.isVisible)?.title ?? "Id"
                let money = cols.first { $0.uidt == "Currency" }?.title
                let date = cols.first { $0.uidt == "Date" }?.title
                let els = Excalidraw.pipelineWall(title: "\(t.title) pipeline", stageColumn: stage, primary: primary, records: rows) { r in
                    [money.flatMap { r[$0]?.double }.map(\.currency), date.flatMap { r[$0]?.string.flatMap(DateField.parse) }?.formatted(.dateTime.month(.abbreviated).day())]
                        .compactMap { $0 }.joined(separator: " · ")
                }
                return Excalidraw.Board(id: UUID().uuidString, name: "\(t.title) pipeline wall", updated: Date(), elements: .array(els))
            }
        }
        throw APIError.notConfigured("A NocoDB table with a Stage or Status column")
    }
}

/// Hosts the open-source Excalidraw web app and hands it the board through its own localStorage keys.
struct BoardEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var board: Excalidraw.Board
    @State private var web = WebHandle()
    @State private var renaming = false

    var body: some View {
        NavigationStack {
            ExcalidrawWebView(elements: board.elements, handle: web)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(board.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { Task { await save(); dismiss() } }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { renaming = true } label: { Image(systemName: "pencil") }
                        ShareLink(item: BoardStore.exportURL(board)) { Image(systemName: "square.and.arrow.up") }
                    }
                }
                .alert("Rename board", isPresented: $renaming) {
                    TextField("Name", text: $board.name)
                    Button("OK") { Task { await save() } }
                }
        }
    }

    private func save() async {
        if let json = await web.read(), let d = json.data(using: .utf8),
           let els = try? JSONDecoder().decode(JSONValue.self, from: d) {
            board.elements = .array(els.array.filter { !($0["isDeleted"]?.bool ?? false) })
        }
        BoardStore.save(board)
    }
}

@MainActor
final class WebHandle {
    weak var view: WKWebView?
    func read() async -> String? {
        try? await view?.evaluateJavaScript("localStorage.getItem('excalidraw')") as? String
    }
}

struct ExcalidrawWebView: UIViewRepresentable {
    let elements: JSONValue
    let handle: WebHandle

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let json = String(decoding: (try? JSONEncoder().encode(elements)) ?? Data("[]".utf8), as: UTF8.self)
        let state = #"{"theme":"light","zoom":{"value":0.55},"scrollX":40,"scrollY":190,"openSidebar":null}"#
        // Runs before Excalidraw boots, so it restores this board instead of whatever was there last.
        let js = "try{localStorage.setItem('excalidraw', \(jsString(json)));localStorage.setItem('excalidraw-state', \(jsString(state)));}catch(e){}"
        cfg.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.isOpaque = false
        v.backgroundColor = .white
        v.load(URLRequest(url: URL(string: "https://excalidraw.com")!))
        handle.view = v
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {}

    private func jsString(_ s: String) -> String {
        let d = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
        return String(decoding: d, as: UTF8.self)
    }
}
