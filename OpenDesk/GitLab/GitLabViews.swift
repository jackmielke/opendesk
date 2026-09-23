import SwiftUI

struct GitLabHomeView: View {
    @Environment(AppConfig.self) private var config
    @State private var pinned: [GLProject] = []
    @State private var mine: [GLProject] = []
    @State private var results: [GLProject] = []
    @State private var query = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error { ErrorCard(message: error) { Task { await load() } }.listRowBackground(Color.clear) }
                if !results.isEmpty {
                    Section("Search results") { ForEach(results) { row($0) } }
                }
                if !mine.isEmpty {
                    Section("Your projects") { ForEach(mine) { row($0) } }
                }
                Section("Pinned open-source projects") { ForEach(pinned) { row($0) } }
            }
            .overlay { if pinned.isEmpty && error == nil { ProgressView() } }
            .navigationTitle("Code")
            .navigationDestination(for: GLProject.self) { ProjectScreen(project: $0) }
            .navigationDestination(for: GLItemRoute.self) { ItemScreen(route: $0) }
            .searchable(text: $query, prompt: "Search GitLab projects")
            .onSubmit(of: .search) { Task { results = (try? await config.gitlab.searchProjects(query)) ?? [] } }
            .onChange(of: query) { if query.isEmpty { results = [] } }
            .refreshable { await load() }
            .task { if pinned.isEmpty { await load() } }
        }
    }

    private func row(_ p: GLProject) -> some View {
        NavigationLink(value: p) {
            HStack(spacing: 12) {
                AsyncImage(url: p.avatar) { img in img.resizable() } placeholder: {
                    Text(p.name.prefix(1).uppercased()).font(.headline)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Brand.gitlab.opacity(0.25))
                }
                .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(.body.weight(.medium))
                    Text(p.path).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label(p.stars.formatted(.number.notation(.compactName)), systemImage: "star").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        let gl = config.gitlab
        let paths = config.pinnedProjects
        var loaded: [GLProject] = []
        await withTaskGroup(of: GLProject?.self) { group in
            for p in paths { group.addTask { try? await gl.project(p) } }
            for await p in group { if let p { loaded.append(p) } }
        }
        pinned = loaded.sorted { (paths.firstIndex(of: $0.path) ?? 99) < (paths.firstIndex(of: $1.path) ?? 99) }
        if gl.hasToken { mine = (try? await gl.myProjects()) ?? [] }
        error = pinned.isEmpty ? "Couldn't reach \(config.gitlabURL)" : nil
    }
}

struct GLItemRoute: Hashable {
    let project: GLProject
    let item: GLItem
    let isMR: Bool
}

struct ProjectScreen: View {
    @Environment(AppConfig.self) private var config
    let project: GLProject
    @State private var tab: Tab = .mrs
    @State private var mrs: [GLItem] = []
    @State private var issues: [GLItem] = []
    @State private var pipelines: [GLPipeline] = []
    @State private var error: String?
    @State private var askAI = false

    enum Tab: String, CaseIterable { case mrs = "Merge requests", issues = "Issues", pipelines = "Pipelines" }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    if let d = project.description, !d.isEmpty { Text(d).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
                    HStack(spacing: 16) {
                        Label(project.stars.formatted(.number.notation(.compactName)), systemImage: "star.fill")
                        Label(project.forks.formatted(.number.notation(.compactName)), systemImage: "tuningfork")
                        if let i = project.openIssues { Label(i.formatted(.number.notation(.compactName)), systemImage: "exclamationmark.circle") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    healthStrip
                }
                Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented)
            }
            if let error { Text(error).foregroundStyle(.orange).font(.footnote) }
            switch tab {
            case .mrs:
                ForEach(mrs) { m in NavigationLink(value: GLItemRoute(project: project, item: m, isMR: true)) { ItemRow(item: m, isMR: true) } }
            case .issues:
                ForEach(issues) { i in NavigationLink(value: GLItemRoute(project: project, item: i, isMR: false)) { ItemRow(item: i, isMR: false) } }
            case .pipelines:
                ForEach(pipelines) { p in NavigationLink { PipelineScreen(project: project, pipeline: p) } label: { PipelineRow(p: p) } }
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { askAI = true } label: { Image(systemName: "sparkles") }
                if let u = project.webURL { ShareLink(item: u) }
            }
        }
        .refreshable { await load() }
        .task { if mrs.isEmpty { await load() } }
        .sheet(isPresented: $askAI) {
            AskSheet(title: "Ask \(project.name)", accent: Brand.gitlab,
                     suggestions: ["What's the state of this project today?", "Which open MRs look closest to merging?", "Are pipelines healthy? What's failing?"]) {
                describe()
            }
        }
    }

    /// The last 30 pipelines as coloured ticks: the project's heartbeat at a glance.
    private var healthStrip: some View {
        HStack(spacing: 2) {
            ForEach(pipelines.prefix(30).reversed()) { p in
                RoundedRectangle(cornerRadius: 2).fill(GLStatus.color(p.status)).frame(height: 14)
            }
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) { if pipelines.isEmpty { Text("").font(.caption2) } }
    }

    private func load() async {
        let gl = config.gitlab
        async let m = gl.mergeRequests(project.id)
        async let i = gl.issues(project.id)
        async let p = gl.pipelines(project.id)
        do { mrs = try await m } catch { self.error = error.localizedDescription }
        issues = (try? await i) ?? []
        pipelines = (try? await p) ?? []
    }

    private func describe() -> String {
        var lines = ["PROJECT \(project.path): \(project.stars) stars, \(project.openIssues ?? 0) open issues. Now: \(Date().formatted())."]
        lines.append("OPEN MERGE REQUESTS:")
        for m in mrs.prefix(25) {
            lines.append("- !\(m.iid) \(m.title) by \(m.author); updated \(relativeDate(m.updatedAt)); \(m.comments) comments; labels: \(m.labels.prefix(4).joined(separator: ","))\(m.draft ? "; DRAFT" : "")")
        }
        lines.append("OPEN ISSUES:")
        for i in issues.prefix(20) { lines.append("- #\(i.iid) \(i.title); \(i.upvotes) upvotes; labels: \(i.labels.prefix(3).joined(separator: ","))") }
        lines.append("RECENT PIPELINES:")
        for p in pipelines.prefix(20) { lines.append("- #\(p.id) \(p.status) on \(p.ref) (\(p.source ?? "")) \(relativeDate(p.createdAt))") }
        return lines.joined(separator: "\n")
    }
}

struct ItemRow: View {
    let item: GLItem
    let isMR: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                if item.draft { Chip(text: "Draft", color: .gray) }
                Text(item.title).font(.subheadline.weight(.medium)).lineLimit(2)
            }
            HStack(spacing: 8) {
                Text((isMR ? "!" : "#") + "\(item.iid)").monospacedDigit()
                Text(item.author).lineLimit(1)
                Text(relativeDate(item.updatedAt))
                Spacer()
                if item.comments > 0 { Label("\(item.comments)", systemImage: "bubble.left") }
                if let s = item.pipelineStatus { Image(systemName: GLStatus.icon(s)).foregroundStyle(GLStatus.color(s)) }
            }
            .font(.caption).foregroundStyle(.secondary)
            if !item.labels.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) { ForEach(item.labels.prefix(5), id: \.self) { Chip(text: $0, color: labelColor($0)) } }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

func labelColor(_ l: String) -> Color {
    let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .mint, .cyan]
    let scope = l.split(separator: ":").first.map(String.init) ?? l
    return palette[abs(scope.hashValue) % palette.count]
}

struct PipelineRow: View {
    let p: GLPipeline
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: GLStatus.icon(p.status)).foregroundStyle(GLStatus.color(p.status)).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("#\(p.id)").font(.subheadline.monospacedDigit().weight(.medium))
                Text("\(p.ref) · \(p.sha)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(p.status.capitalized).font(.caption.weight(.semibold)).foregroundStyle(GLStatus.color(p.status))
                Text(relativeDate(p.createdAt)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct PipelineScreen: View {
    @Environment(AppConfig.self) private var config
    let project: GLProject
    let pipeline: GLPipeline
    @State private var jobs: [GLJob] = []
    @State private var message: String?

    var body: some View {
        List {
            Section { PipelineRow(p: pipeline) }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            let stages = jobs.reduce(into: [String]()) { if !$0.contains($1.stage) { $0.append($1.stage) } }
            ForEach(stages, id: \.self) { stage in
                Section(stage) {
                    ForEach(jobs.filter { $0.stage == stage }) { j in
                        HStack {
                            Image(systemName: GLStatus.icon(j.status)).foregroundStyle(GLStatus.color(j.status))
                            Text(j.name).font(.subheadline).lineLimit(1)
                            Spacer()
                            if let d = j.duration { Text(Duration.seconds(d).formatted(.units(allowed: [.minutes, .seconds], width: .narrow))).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Pipeline #\(pipeline.id)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if config.gitlab.hasToken && pipeline.status == "failed" {
                Button("Retry") {
                    Task {
                        do { try await config.gitlab.retry(project.id, pipeline: pipeline.id); message = "Retry requested." }
                        catch { message = error.localizedDescription }
                    }
                }
            }
        }
        .task {
            do { jobs = try await config.gitlab.jobs(project.id, pipeline: pipeline.id) }
            catch { message = "Jobs need a token for this project." }
        }
    }
}

struct ItemScreen: View {
    @Environment(AppConfig.self) private var config
    let route: GLItemRoute
    @State private var item: GLItem?
    @State private var diffs: [GLDiff] = []
    @State private var notes: [GLNote] = []
    @State private var summary: String?
    @State private var summarizing = false
    @State private var reply = ""
    @State private var status: String?

    private var kind: String { route.isMR ? "merge_requests" : "issues" }

    var body: some View {
        let it = item ?? route.item
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(it.title).font(.title3.weight(.semibold))
                    HStack {
                        Chip(text: it.state.capitalized, color: GLStatus.color(it.state))
                        if let s = it.pipelineStatus { Chip(text: "CI \(s)", color: GLStatus.color(s)) }
                        if let m = it.mergeStatus, route.isMR { Chip(text: m.replacingOccurrences(of: "_", with: " "), color: m == "mergeable" ? .green : .orange) }
                    }
                    Text("\(it.author) · opened \(relativeDate(it.createdAt))").font(.caption).foregroundStyle(.secondary)
                    if route.isMR, let s = it.sourceBranch, let t = it.targetBranch {
                        Text("\(s) → \(t)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }

            Section {
                if let summary {
                    Text(markdown(summary)).font(.subheadline)
                } else {
                    Button { Task { await summarize() } } label: {
                        HStack {
                            Label(route.isMR ? "Summarize this change" : "Summarize this issue", systemImage: "sparkles")
                            if summarizing { Spacer(); ProgressView() }
                        }
                    }
                    .tint(Brand.ai)
                }
            } header: { Text("AI brief") }

            if let d = it.description, !d.isEmpty {
                Section("Description") { Text(markdown(String(d.prefix(3000)))).font(.subheadline) }
            }

            if route.isMR && !diffs.isEmpty {
                Section("\(diffs.count) files · +\(diffs.map(\.added).reduce(0, +)) −\(diffs.map(\.removed).reduce(0, +))") {
                    ForEach(diffs) { f in
                        NavigationLink { DiffView(file: f) } label: {
                            HStack {
                                Image(systemName: f.isNew ? "doc.badge.plus" : f.isDeleted ? "doc.badge.minus" : "doc.text")
                                Text(f.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.head)
                                Spacer()
                                Text("+\(f.added)").foregroundStyle(.green).font(.caption.monospacedDigit())
                                Text("−\(f.removed)").foregroundStyle(.red).font(.caption.monospacedDigit())
                            }
                        }
                    }
                }
            }

            if !notes.isEmpty {
                Section("Discussion") {
                    ForEach(notes) { n in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(n.author) · \(relativeDate(n.createdAt))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(markdown(String(n.body.prefix(800)))).font(.subheadline)
                        }
                    }
                }
            }

            if config.gitlab.hasToken {
                Section("Reply") {
                    TextField("Write a comment…", text: $reply, axis: .vertical).lineLimit(2...6)
                    Button("Post comment") { Task { await post() } }.disabled(reply.isEmpty)
                    if route.isMR { Button("Approve") { Task { await approve() } }.tint(.green) }
                    if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle((route.isMR ? "!" : "#") + "\(route.item.iid)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if let u = it.webURL { ShareLink(item: u) } }
        .task { await load() }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s.bulleted, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    private func load() async {
        let gl = config.gitlab
        let pid = route.project.id, iid = route.item.iid
        if route.isMR {
            async let full = gl.mergeRequest(pid, iid: iid)
            async let d = gl.diffs(pid, iid: iid)
            item = try? await full
            diffs = (try? await d) ?? []
        }
        notes = (try? await gl.notes(pid, kind: kind, iid: iid)) ?? []
    }

    private func summarize() async {
        summarizing = true
        defer { summarizing = false }
        let it = item ?? route.item
        var ctx = "\(route.isMR ? "MERGE REQUEST" : "ISSUE") in \(route.project.path): \(it.title)\nDESCRIPTION:\n\(String((it.description ?? "").prefix(1500)))\n"
        if !diffs.isEmpty {
            ctx += "FILES CHANGED:\n" + diffs.prefix(25).map { "\($0.path) +\($0.added) -\($0.removed)" }.joined(separator: "\n")
            ctx += "\nDIFF EXCERPT:\n" + String(diffs.prefix(3).map(\.diff).joined(separator: "\n").prefix(1500))
        }
        if !notes.isEmpty { ctx += "\nDISCUSSION:\n" + notes.suffix(6).map { "\($0.author): \($0.body.prefix(200))" }.joined(separator: "\n") }
        let q = route.isMR
            ? "In 3 short bullets: what this change does, how risky it is, and what a reviewer should check."
            : "In 3 short bullets: the problem, current status of the discussion, and a suggested next step."
        do { summary = try await AI.ask(q, context: String(ctx.prefix(AI.contextBudget(config))), config: config) }
        catch { summary = error.localizedDescription }
    }

    private func post() async {
        do {
            try await config.gitlab.comment(route.project.id, kind: kind, iid: route.item.iid, body: reply)
            reply = ""
            status = "Posted."
            notes = (try? await config.gitlab.notes(route.project.id, kind: kind, iid: route.item.iid)) ?? notes
        } catch { status = error.localizedDescription }
    }

    private func approve() async {
        do { try await config.gitlab.approve(route.project.id, iid: route.item.iid); status = "Approved." }
        catch { status = error.localizedDescription }
    }
}

struct DiffView: View {
    let file: GLDiff
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(file.diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                    Text(String(line))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(line.hasPrefix("+") ? .green : line.hasPrefix("-") ? .red : line.hasPrefix("@@") ? .cyan : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(line.hasPrefix("+") ? Color.green.opacity(0.1) : line.hasPrefix("-") ? Color.red.opacity(0.1) : .clear)
                }
            }
            .padding(8)
        }
        .navigationTitle((file.path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
    }
}
