import SwiftUI

struct RecordEditor: View {
    @Environment(AppConfig.self) private var config
    @Environment(\.dismiss) private var dismiss
    let model: TableModel
    let record: NocoRecord?
    @State private var draft: NocoRecord = [:]
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDelete = false

    private var isNew: Bool { record == nil }

    var body: some View {
        NavigationStack {
            Form {
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                ForEach(model.visibleColumns) { c in
                    Section {
                        field(c)
                    } header: {
                        Label(c.title, systemImage: c.icon)
                    }
                }
                if !isNew {
                    Section {
                        Button("Delete row", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(isNew ? "New \(model.table.title.singular)" : (model.primary.flatMap { draft[$0.title]?.display } ?? "Row"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") { Task { await save() } }
                        .disabled(saving || changes.isEmpty)
                }
            }
            .confirmationDialog("Delete this row?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await delete() } }
            }
            .onAppear { draft = record ?? [:] }
        }
    }

    private var changes: [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for c in model.columns where c.isEditable {
            let new = draft[c.title] ?? .null
            let old = record?[c.title] ?? .null
            if new != old && !(new.isNull && old.isNull) { out[c.title] = new }
        }
        return out
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { draft[key]?.string ?? "" }, set: { draft[key] = $0.isEmpty ? .null : .string($0) })
    }

    @ViewBuilder
    private func field(_ c: NocoColumn) -> some View {
        if !c.isEditable {
            Text(FieldText.format(c, draft[c.title])).foregroundStyle(.secondary)
        } else {
            switch c.uidt {
            case "LongText":
                TextField(c.title, text: binding(c.title), axis: .vertical).lineLimit(3...8)
            case "Number", "Currency", "Decimal", "Percent":
                TextField("0", text: Binding(
                    get: { draft[c.title]?.string ?? "" },
                    set: { draft[c.title] = Double($0).map(JSONValue.number) ?? .null }))
                    .keyboardType(.decimalPad)
            case "Checkbox":
                Toggle(c.title, isOn: Binding(get: { draft[c.title]?.bool ?? false }, set: { draft[c.title] = .bool($0) }))
            case "Rating":
                HStack {
                    ForEach(1...5, id: \.self) { i in
                        Image(systemName: i <= (draft[c.title]?.int ?? 0) ? "star.fill" : "star")
                            .foregroundStyle(.yellow)
                            .onTapGesture { draft[c.title] = .number(Double(i)) }
                    }
                }
            case "SingleSelect":
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(c.options, id: \.title) { o in
                            let on = draft[c.title]?.string == o.title
                            Button { draft[c.title] = on ? .null : .string(o.title) } label: {
                                Text(o.title).font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(vivid(o.color).opacity(on ? 0.9 : 0.15), in: Capsule())
                                    .foregroundStyle(on ? .black : vivid(o.color))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            case "MultiSelect":
                let selected = Set((draft[c.title]?.string ?? "").split(separator: ",").map(String.init))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(c.options, id: \.title) { o in
                            let on = selected.contains(o.title)
                            Button {
                                var s = selected
                                if on { s.remove(o.title) } else { s.insert(o.title) }
                                let ordered = c.options.map(\.title).filter(s.contains)
                                draft[c.title] = ordered.isEmpty ? .null : .string(ordered.joined(separator: ","))
                            } label: {
                                Text(o.title).font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(vivid(o.color).opacity(on ? 0.9 : 0.15), in: Capsule())
                                    .foregroundStyle(on ? .black : vivid(o.color))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            case "Date":
                DatePicker(c.title, selection: Binding(
                    get: { draft[c.title]?.string.flatMap(DateField.parse) ?? Date() },
                    set: { draft[c.title] = .string(DateField.string($0)) }), displayedComponents: .date)
            case "Email":
                HStack {
                    TextField("name@example.com", text: binding(c.title)).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    if let e = draft[c.title]?.string, let u = URL(string: "mailto:\(e)") { Link(destination: u) { Image(systemName: "envelope.fill") } }
                }
            case "PhoneNumber":
                HStack {
                    TextField("Phone", text: binding(c.title)).keyboardType(.phonePad)
                    if let p = draft[c.title]?.string, let u = URL(string: "tel:" + p.filter(\.isNumber)) { Link(destination: u) { Image(systemName: "phone.fill") } }
                }
            case "URL":
                TextField("https://", text: binding(c.title)).keyboardType(.URL).textInputAutocapitalization(.never)
            default:
                TextField(c.title, text: binding(c.title))
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            if let record {
                try await model.source.update(id: record.recordId, fields: changes)
            } else {
                try await model.source.create(fields: changes)
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await model.load()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete() async {
        guard let record else { return }
        do {
            try await model.source.delete(id: record.recordId)
            await model.load()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension String {
    var singular: String { hasSuffix("s") ? String(dropLast()) : self }
}
