import SwiftUI
import UniformTypeIdentifiers

struct ProjectsView: View {
    @Environment(ProjectStore.self) private var store
    @State private var showImporter = false

    var body: some View {
        List {
            if store.projects.isEmpty && !store.isImporting {
                ContentUnavailableView {
                    Label("Nessun progetto", systemImage: "doc.zipper")
                } description: {
                    Text("Importa un file .zip contenente una repository con i workflow in .github/workflows. Puoi anche usare \"Download ZIP\" da GitHub.")
                } actions: {
                    Button("Importa ZIP") { showImporter = true }.buttonStyle(.borderedProminent)
                }
            }
            if store.isImporting {
                HStack { ProgressView(); Text("Importazione in corso…") }
            }
            if let e = store.importError {
                Text(e).foregroundStyle(.red).font(.footnote)
            }
            ForEach(store.projects) { p in
                NavigationLink(value: p.id) {
                    ProjectRow(project: p)
                }
            }
            .onDelete { idx in
                for i in idx { store.delete(store.projects[i]) }
            }
        }
        .navigationTitle("Actions Runner")
        .navigationDestination(for: UUID.self) { id in
            ProjectDetailView(projectId: id)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showImporter = true } label: { Label("Importa", systemImage: "plus") }
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
    var body: some View {
        let workflows = WorkflowParser.loadWorkflows(in: project.repoURL).workflows
        VStack(alignment: .leading, spacing: 4) {
            Text(project.name).font(.headline)
            HStack(spacing: 10) {
                Label("\(workflows.count)", systemImage: "gearshape.2")
                Label("\(project.fileCount)", systemImage: "doc")
                Text(Format.bytes(project.sizeBytes))
                if let r = project.githubRepo { Label(r, systemImage: "cloud") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct ProjectDetailView: View {
    let projectId: UUID
    @Environment(ProjectStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(RunCenter.self) private var runs
    @State private var workflows: [Workflow] = []
    @State private var loadErrors: [Diagnostic] = []
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var showRename = false
    @State private var newName = ""

    var body: some View {
        if let project = store.project(projectId) {
            List {
                Section {
                    LabeledContent("File", value: "\(project.fileCount)")
                    LabeledContent("Dimensione", value: Format.bytes(project.sizeBytes))
                    LabeledContent("Importato", value: project.importedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Sorgente", value: project.sourceFileName)
                    if let o = project.githubOwner, let r = project.githubRepo {
                        Link(destination: URL(string: "https://github.com/\(o)/\(r)")!) {
                            Label("\(o)/\(r)", systemImage: "arrow.up.right.square")
                        }
                    }
                }

                Section("Workflow (.github/workflows)") {
                    if workflows.isEmpty && loadErrors.isEmpty {
                        Text("Nessun workflow trovato. La repo deve contenere file .yml in .github/workflows/.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(workflows) { wf in
                        NavigationLink {
                            WorkflowDetailView(project: project, workflow: wf)
                        } label: {
                            WorkflowRow(workflow: wf)
                        }
                    }
                    ForEach(loadErrors) { d in
                        Label(d.message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).font(.footnote)
                    }
                }

                Section("Repository") {
                    NavigationLink {
                        FileBrowserView(root: project.repoURL, url: project.repoURL, title: project.name)
                    } label: { Label("Sfoglia i file", systemImage: "folder") }
                    Button {
                        do { exportURL = try store.export(project) } catch { exportError = error.localizedDescription }
                    } label: { Label("Esporta come ZIP", systemImage: "square.and.arrow.up") }
                    if let u = exportURL {
                        ShareLink(item: u) { Label("Condividi \(u.lastPathComponent)", systemImage: "square.and.arrow.up.on.square") }
                    }
                    if let e = exportError { Text(e).foregroundStyle(.red).font(.footnote) }
                }

                if !project.cloudRuns.isEmpty {
                    Section("Esecuzioni su GitHub") {
                        ForEach(project.cloudRuns.prefix(20)) { r in
                            NavigationLink {
                                CloudRunAttachView(record: r)
                            } label: {
                                HStack {
                                    StatusIcon(api: r.conclusion == nil ? "in_progress" : "completed", conclusion: r.conclusion)
                                    VStack(alignment: .leading) {
                                        Text("#\(r.runId) · \((r.workflow as NSString).lastPathComponent)").font(.subheadline)
                                        Text(Format.relative.localizedString(for: r.date, relativeTo: Date())).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Impostazioni GitHub del progetto") {
                    ProjectGitHubFields(project: project)
                }
            }
            .navigationTitle(project.name)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { newName = project.name; showRename = true } label: { Image(systemName: "pencil") }
                }
            }
            .alert("Rinomina progetto", isPresented: $showRename) {
                TextField("Nome", text: $newName)
                Button("Salva") { var p = project; p.name = newName; store.update(p) }
                Button("Annulla", role: .cancel) {}
            }
            .task { reload(project) }
            .refreshable { reload(project) }
        } else {
            ContentUnavailableView("Progetto non trovato", systemImage: "questionmark.folder")
        }
    }

    private func reload(_ p: Project) {
        let r = WorkflowParser.loadWorkflows(in: p.repoURL)
        workflows = r.workflows
        loadErrors = r.errors
    }
}

struct ProjectGitHubFields: View {
    let project: Project
    @Environment(ProjectStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var owner = ""
    @State private var repo = ""
    @State private var branch = ""

    var body: some View {
        Group {
            TextField("Owner (vuoto = \(settings.effectiveOwner.isEmpty ? "il tuo account" : settings.effectiveOwner))", text: $owner)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Repository (vuoto = \(Project.sanitizedRepoName(settings.repoPrefix + project.name)))", text: $repo)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Branch (vuoto = default)", text: $branch)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Salva") {
                var p = project
                p.githubOwner = owner.isEmpty ? nil : owner
                p.githubRepo = repo.isEmpty ? nil : repo
                p.githubBranch = branch.isEmpty ? nil : branch
                store.update(p)
            }
        }
        .onAppear {
            owner = project.githubOwner ?? ""
            repo = project.githubRepo ?? ""
            branch = project.githubBranch ?? ""
        }
    }
}

struct WorkflowRow: View {
    let workflow: Workflow
    var body: some View {
        let errors = workflow.diagnostics.filter { $0.severity == .error }.count
        let warnings = workflow.diagnostics.filter { $0.severity == .warning }.count
        VStack(alignment: .leading, spacing: 3) {
            Text(workflow.name).font(.headline)
            Text(workflow.path).font(.caption.monospaced()).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(workflow.eventNames.joined(separator: ", ")).font(.caption2).foregroundStyle(.blue)
                Text("\(workflow.jobs.count) job").font(.caption2).foregroundStyle(.secondary)
                if errors > 0 { Label("\(errors)", systemImage: "xmark.octagon.fill").font(.caption2).foregroundStyle(.red) }
                if warnings > 0 { Label("\(warnings)", systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange) }
            }
        }
    }
}

// MARK: - File browser

struct FileBrowserView: View {
    let root: URL
    let url: URL
    let title: String
    @State private var items: [URL] = []

    var body: some View {
        List(items, id: \.self) { item in
            if FileCommands.isDir(item) {
                NavigationLink {
                    FileBrowserView(root: root, url: item, title: item.lastPathComponent)
                } label: { Label(item.lastPathComponent, systemImage: "folder.fill") }
            } else {
                NavigationLink {
                    FileViewer(url: item)
                } label: {
                    HStack {
                        Label(item.lastPathComponent, systemImage: icon(item))
                        Spacer()
                        Text(Format.bytes(Int64(((try? FileManager.default.attributesOfItem(atPath: item.path))?[.size] as? NSNumber)?.intValue ?? 0)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let fm = FileManager.default
            let all = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            items = all.sorted { a, b in
                let da = FileCommands.isDir(a), db = FileCommands.isDir(b)
                if da != db { return da }
                return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }
        }
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
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        Group {
            if editing {
                TextEditor(text: $draft)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } else if let t = text {
                ScrollView([.vertical, .horizontal]) {
                    Text(t)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("File binario", systemImage: "doc", description: Text(url.lastPathComponent))
            }
        }
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if text != nil {
                ToolbarItem(placement: .primaryAction) {
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
            ToolbarItem(placement: .secondaryAction) { ShareLink(item: url) }
        }
        .onAppear {
            if let data = try? Data(contentsOf: url), data.count < 5_000_000, !data.prefix(8000).contains(0) {
                text = String(decoding: data, as: UTF8.self)
            }
        }
    }
}
