import SwiftUI
import UniformTypeIdentifiers

struct ProjectsView: View {
    @Environment(ProjectStore.self) private var store
    @State private var showImporter = false

    var body: some View {
        GlassList {
            GlassHeroCard(eyebrow: "ACTIONS RUNNER", title: "GitHub Actions,\nin tasca.",
                          subtitle: "Importa una repository ed eseguila sui runner di GitHub")
                .glassListRow()

            if store.isImporting {
                HStack(spacing: 13) {
                    ProgressView().tint(Color.glassInk)
                    Text("Importazione in corso…")
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                }
                .glassSection(cornerRadius: 24)
                .glassListRow()
            }

            if let e = store.importError {
                GlassErrorText(message: e).glassListRow()
            }

            if store.projects.isEmpty && !store.isImporting {
                GlassEmptyState(symbol: "doc.zipper", title: "Nessun progetto",
                                message: "Importa un file .zip con una repository che contiene i workflow in .github/workflows. Va bene anche il \"Download ZIP\" di GitHub.")
                    .glassListRow()
            } else if !store.projects.isEmpty {
                GlassListHeader(title: "Progetti", count: store.projects.count, symbol: "shippingbox.fill")
                    .glassListRow(top: 12)
            }

            ForEach(store.projects) { p in
                ProjectRow(project: p)
                    .overlay { NavigationLink(value: p.id) { EmptyView() }.opacity(0) }
                    .glassListRow()
            }
            .onDelete { idx in
                for i in idx { store.delete(store.projects[i]) }
            }

            Button { showImporter = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down")
                    Text("Importa ZIP")
                }
            }
            .buttonStyle(LiquidGlassButtonStyle(prominent: true))
            .disabled(store.isImporting)
            .glassListRow(top: 12)
        }
        .navigationTitle("Progetti")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: UUID.self) { id in
            ProjectDetailView(projectId: id)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImporter = true } label: {
                    Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
                }
                .accessibilityLabel("Importa")
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.zip, .folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { _ = await store.importItem(at: url) }
            }
        }
    }
}

struct ProjectRow: View {
    let project: Project
    @State private var workflowCount: Int?

    var body: some View {
        HStack(spacing: 14) {
            GlassIconBadge(symbol: "shippingbox", size: 48)
            VStack(alignment: .leading, spacing: 5) {
                Text(project.name)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 10) {
                    Label(workflowCount.map(String.init) ?? "–", systemImage: "gearshape.2")
                    Label("\(project.fileCount)", systemImage: "doc")
                    Text(Format.bytes(project.sizeBytes))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let r = project.githubRepo {
                    Text(r)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            GlassChevron()
        }
        .glassRow()
        .task(id: project.repoURL) {
            let url = project.repoURL
            workflowCount = await Task.detached(priority: .userInitiated) {
                WorkflowParser.loadWorkflows(in: url).workflows.count
            }.value
        }
    }
}

struct ProjectDetailView: View {
    let projectId: UUID
    @Environment(ProjectStore.self) private var store
    @State private var workflows: [Workflow] = []
    @State private var loadErrors: [Diagnostic] = []
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var showRename = false
    @State private var newName = ""

    var body: some View {
        if let project = store.project(projectId) {
            GlassScreen {
                VStack(alignment: .leading, spacing: 14) {
                    GlassSectionHeading(title: project.name, subtitle: project.sourceFileName, symbol: "shippingbox")
                    GlassDetailRow(title: "File", value: "\(project.fileCount) · \(Format.bytes(project.sizeBytes))", symbol: "doc.on.doc")
                    GlassDivider()
                    GlassDetailRow(title: "Importato", value: project.importedAt.formatted(date: .abbreviated, time: .shortened), symbol: "calendar")
                    if let r = project.githubRepo {
                        GlassDivider()
                        GlassDetailRow(title: "Repository GitHub", value: "\(r) · \(project.githubBranch ?? "—")", symbol: "arrow.triangle.branch")
                    }
                }
                .glassSection()

                GlassListHeader(title: "Workflow", count: workflows.count, symbol: "gearshape.2.fill")

                if workflows.isEmpty && loadErrors.isEmpty {
                    GlassEmptyState(symbol: "gearshape.2", title: "Nessun workflow",
                                    message: "La repository deve contenere file .yml in .github/workflows/.")
                }
                LazyVStack(spacing: 12) {
                    ForEach(workflows) { wf in
                        NavigationLink {
                            WorkflowDetailView(project: project, workflow: wf)
                        } label: {
                            WorkflowRow(workflow: wf)
                        }
                        .buttonStyle(.plain)
                    }
                }
                ForEach(loadErrors) { d in
                    GlassErrorText(message: [d.message, d.location].compactMap { $0 }.joined(separator: " · "))
                }

                VStack(alignment: .leading, spacing: 14) {
                    GlassSectionHeading(title: "Repository", subtitle: "File importati sul dispositivo.", symbol: "folder")
                    NavigationLink {
                        FileBrowserView(root: project.repoURL, url: project.repoURL, title: project.name)
                    } label: {
                        Label("Sfoglia i file", systemImage: "folder")
                    }
                    .buttonStyle(LiquidGlassButtonStyle())
                    Button {
                        do { exportURL = try store.export(project) } catch { exportError = error.localizedDescription }
                    } label: {
                        Label("Esporta come ZIP", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(LiquidGlassButtonStyle())
                    if let u = exportURL {
                        ShareLink(item: u) {
                            Label("Condividi \(u.lastPathComponent)", systemImage: "square.and.arrow.up.on.square")
                        }
                        .buttonStyle(LiquidGlassButtonStyle(prominent: true))
                    }
                    if let e = exportError {
                        Text(e).font(.footnote).foregroundStyle(.red)
                    }
                }
                .glassSection()
            }
            .navigationTitle(project.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { newName = project.name; showRename = true } label: {
                        Image(systemName: "pencil").font(.system(size: 15, weight: .semibold))
                    }
                    .accessibilityLabel("Rinomina")
                }
            }
            .alert("Rinomina progetto", isPresented: $showRename) {
                TextField("Nome", text: $newName)
                Button("Salva") { var p = project; p.name = newName; store.update(p) }
                Button("Annulla", role: .cancel) {}
            }
            .task { await reload(project) }
            .refreshable { await reload(project) }
        } else {
            ZStack {
                AppGlassBackground()
                GlassEmptyState(symbol: "questionmark.folder", title: "Progetto non trovato", message: "Il progetto è stato eliminato.")
                    .padding(18)
            }
        }
    }

    /// Lettura e analisi dei workflow fuori dal main thread: la navigazione resta fluida.
    private func reload(_ p: Project) async {
        let url = p.repoURL
        let r = await Task.detached(priority: .userInitiated) { WorkflowParser.loadWorkflows(in: url) }.value
        workflows = r.workflows
        loadErrors = r.errors
    }
}

struct WorkflowRow: View {
    let workflow: Workflow
    var body: some View {
        let errors = workflow.diagnostics.filter { $0.severity == .error }.count
        let warnings = workflow.diagnostics.filter { $0.severity == .warning }.count
        HStack(spacing: 14) {
            GlassIconBadge(symbol: "gearshape.2", size: 48)
            VStack(alignment: .leading, spacing: 5) {
                Text(workflow.name)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Text(workflow.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(workflow.eventNames.joined(separator: ", "))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.glassInk.opacity(0.85))
                        .lineLimit(1)
                    Text("\(workflow.jobs.count) job").font(.caption2).foregroundStyle(.secondary)
                    if errors > 0 { Label("\(errors)", systemImage: "xmark.octagon.fill").font(.caption2).foregroundStyle(.red) }
                    if warnings > 0 { Label("\(warnings)", systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange) }
                }
            }
            Spacer(minLength: 4)
            GlassChevron()
        }
        .glassRow()
    }
}

// MARK: - File

struct FileBrowserView: View {
    let root: URL
    let url: URL
    let title: String
    @State private var items: [URL] = []
    @State private var info: [URL: (isDir: Bool, size: Int64)] = [:]
    @State private var loaded = false

    var body: some View {
        GlassScreen(spacing: 12) {
            if loaded && items.isEmpty {
                GlassEmptyState(symbol: "folder", title: "Cartella vuota", message: url.lastPathComponent)
            }
            LazyVStack(spacing: 10) {
                ForEach(items, id: \.self) { item in
                    if info[item]?.isDir == true {
                        NavigationLink {
                            FileBrowserView(root: root, url: item, title: item.lastPathComponent)
                        } label: {
                            fileRow(item, symbol: "folder.fill", detail: nil)
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink {
                            FileViewer(url: item)
                        } label: {
                            fileRow(item, symbol: icon(item),
                                    detail: Format.bytes(info[item]?.size ?? 0))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded else { return }
            let dir = url
            let (sorted, meta) = await Task.detached(priority: .userInitiated) { () -> ([URL], [URL: (isDir: Bool, size: Int64)]) in
                let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
                let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
                var meta: [URL: (isDir: Bool, size: Int64)] = [:]
                for u in all {
                    let v = try? u.resourceValues(forKeys: Set(keys))
                    meta[u] = (v?.isDirectory ?? false, Int64(v?.fileSize ?? 0))
                }
                let sorted = all.sorted { a, b in
                    let da = meta[a]?.isDir ?? false, db = meta[b]?.isDir ?? false
                    if da != db { return da }
                    return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
                }
                return (sorted, meta)
            }.value
            info = meta
            items = sorted
            loaded = true
        }
    }

    private func fileRow(_ item: URL, symbol: String, detail: String?) -> some View {
        HStack(spacing: 12) {
            GlassIconBadge(symbol: symbol, size: 38)
            Text(item.lastPathComponent)
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 4)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            GlassChevron()
        }
        .glassRow()
    }

    private func icon(_ u: URL) -> String {
        switch u.pathExtension.lowercased() {
        case "yml", "yaml": return "gearshape"
        case "swift": return "swift"
        case "md": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "heic": return "photo"
        case "zip", "ipa": return "doc.zipper"
        case "sh": return "terminal"
        default: return "doc.text"
        }
    }
}

struct FileViewer: View {
    let url: URL
    @State private var text: String?
    @State private var textLoaded = false
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        ZStack {
            AppGlassBackground()

            Group {
                if editing {
                    TextEditor(text: $draft)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .liquidGlassCard(cornerRadius: 22, borderOpacity: 0.11)
                        .padding(18)
                } else if let t = text {
                    ScrollView([.vertical, .horizontal]) {
                        Text(t)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .liquidGlassCard(cornerRadius: 22, borderOpacity: 0.11)
                    .padding(18)
                } else if !textLoaded {
                    ProgressView().tint(Color.glassInk)
                } else {
                    GlassEmptyState(symbol: "doc", title: "File binario", message: url.lastPathComponent)
                        .padding(18)
                }
            }
        }
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if text != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editing ? "Salva" : "Modifica") {
                        if editing {
                            try? draft.write(to: url, atomically: true, encoding: .utf8)
                            text = draft
                        } else {
                            draft = text ?? ""
                        }
                        editing.toggle()
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) { ShareLink(item: url) }
        }
        .task {
            guard !textLoaded else { return }
            let u = url
            text = await Task.detached(priority: .userInitiated) { () -> String? in
                guard let data = try? Data(contentsOf: u), data.count < 5_000_000, !data.prefix(8000).contains(0) else { return nil }
                return String(decoding: data, as: UTF8.self)
            }.value
            textLoaded = true
        }
    }
}
