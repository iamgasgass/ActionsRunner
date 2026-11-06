import SwiftUI

// MARK: - Account

struct GitHubAccountView: View {
    @State private var token = ""
    @State private var info: GitHubAPI.TokenInfo?
    @State private var error: String?
    @State private var checking = false
    @State private var hasToken = GitHubAPI.stored != nil

    static let classicTokenURL = URL(string: "https://github.com/settings/tokens/new?scopes=repo,workflow&description=ActionsRunner%20iOS")!
    static let fineGrainedURL = URL(string: "https://github.com/settings/personal-access-tokens/new")!

    var body: some View {
        Form {
            if hasToken {
                Section("Account collegato") {
                    if checking { HStack { ProgressView(); Text("Verifica…") } }
                    if let info {
                        LabeledContent("Utente", value: info.user.login)
                        if let scopes = info.scopes {
                            LabeledContent("Scope", value: scopes.isEmpty ? "nessuno" : scopes.joined(separator: ", "))
                            let missing = ["repo", "workflow"].filter { !scopes.contains($0) }
                            if !missing.isEmpty {
                                Label("Mancano gli scope: \(missing.joined(separator: ", ")). Senza 'workflow' GitHub rifiuta il caricamento dei file in .github/workflows.",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        } else {
                            LabeledContent("Tipo", value: "fine-grained")
                        }
                        if let r = info.rateRemaining { LabeledContent("Richieste API rimaste (ora)", value: "\(r)") }
                    }
                    Button("Verifica di nuovo") { Task { await verify() } }.disabled(checking)
                    Button("Rimuovi token", role: .destructive) {
                        Keychain.set(nil, for: GitHubAPI.tokenAccount)
                        hasToken = false
                        info = nil
                    }
                }
            }
            Section {
                SecureField("ghp_… oppure github_pat_…", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                Button(hasToken ? "Sostituisci e verifica" : "Salva e verifica") {
                    let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        checking = true
                        defer { checking = false }
                        do {
                            let i = try await GitHubAPI(token: t).verify()
                            Keychain.set(t, for: GitHubAPI.tokenAccount)
                            info = i
                            hasToken = true
                            token = ""
                            error = nil
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checking)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            } header: { Text(hasToken ? "Nuovo token" : "Token di accesso personale") } footer: {
                Text("Il token resta nel portachiavi del dispositivo (solo questo iPhone) e viene inviato soltanto a api.github.com.")
            }
            Section("Come crearlo") {
                Link(destination: GitHubAccountView.classicTokenURL) {
                    Label("Token classic con scope repo e workflow (consigliato)", systemImage: "key")
                }
                Link(destination: GitHubAccountView.fineGrainedURL) {
                    Label("Token fine-grained", systemImage: "key.horizontal")
                }
                Text("Per un token fine-grained concedi sui repository scelti: Contents, Actions, Workflows, Secrets e Variables in lettura e scrittura (Administration in scrittura per creare repository dall'app).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Account GitHub")
        .task { if hasToken && info == nil { await verify() } }
    }

    private func verify() async {
        guard let api = GitHubAPI.stored else { return }
        checking = true
        defer { checking = false }
        do {
            info = try await api.verify()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Scelta del repository

struct RepoPickerView: View {
    let api: GitHubAPI
    let suggestedName: String
    let onSelect: (GHRepo) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var repos: [GHRepo] = []
    @State private var loading = true
    @State private var error: String?
    @State private var search = ""
    @State private var newName = ""
    @State private var newPrivate = true
    @State private var creating = false

    var body: some View {
        List {
            Section {
                TextField("Nome", text: $newName)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Privato", isOn: $newPrivate)
                Button {
                    Task {
                        creating = true
                        defer { creating = false }
                        do {
                            let r = try await GitHubActions.createRepository(api: api, name: newName.trimmingCharacters(in: .whitespaces), isPrivate: newPrivate)
                            onSelect(r)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                } label: {
                    HStack { Text("Crea repository"); if creating { Spacer(); ProgressView() } }
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || creating)
            } header: { Text("Nuovo repository") } footer: {
                Text("Consigliato: un repository dedicato, così il branch contiene esattamente il progetto importato.")
            }
            if let error { Section { Text(error).font(.caption).foregroundStyle(.red) } }
            Section("I tuoi repository") {
                if loading { HStack { ProgressView(); Text("Caricamento…") } }
                ForEach(filtered) { r in
                    Button {
                        onSelect(r)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: r.private ? "lock.fill" : "globe").foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(r.fullName).foregroundStyle(.primary)
                                if let p = GHDate.parse(r.pushedAt) {
                                    Text("aggiornato \(Format.relative.localizedString(for: p, relativeTo: Date()))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if r.permissions?.push == false { Text("sola lettura").font(.caption2).foregroundStyle(.orange) }
                        }
                    }
                    .disabled(r.permissions?.push == false)
                }
            }
        }
        .searchable(text: $search, prompt: "Cerca")
        .navigationTitle("Repository")
        .task {
            if newName.isEmpty { newName = suggestedName }
            do {
                repos = try await GitHubActions.listRepositories(api: api)
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    private var filtered: [GHRepo] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? repos : repos.filter { $0.fullName.lowercased().contains(q) }
    }
}

// MARK: - Configurazione dell'esecuzione su GitHub

struct CloudRunConfigView: View {
    let project: Project
    let workflow: Workflow
    let onStart: (CloudRunModel) -> Void
    @Environment(RunCenter.self) private var runs
    @Environment(AppSettings.self) private var settings
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var repo = ""
    @State private var branch = ""
    @State private var trigger: CloudTrigger = .auto
    @State private var inputs: [String: String] = [:]
    @State private var commitMessage = ""
    @State private var syncSecrets = false
    @State private var api = GitHubAPI.stored
    @State private var loadingBranch = false

    private var usesDispatch: Bool {
        trigger == .dispatch || (trigger == .auto && workflow.supportsDispatch)
    }

    private var macJobs: [String] {
        workflow.jobs.filter { j in
            let ro = j.runsOn?.scalarString ?? j.runsOn?.toJSON(pretty: false) ?? ""
            return ro.lowercased().contains("macos")
        }.map(\.displayName)
    }

    var body: some View {
        Form {
            if api == nil {
                Section {
                    Label("Collega il tuo account GitHub per eseguire il workflow sui runner di GitHub.", systemImage: "person.crop.circle.badge.exclamationmark")
                    NavigationLink("Configura il token") { GitHubAccountView() }
                }
            } else {
                Section {
                    if let api {
                        NavigationLink {
                            RepoPickerView(api: api, suggestedName: Project.sanitizedRepoName(project.name)) { r in
                                repo = r.fullName
                                branch = r.defaultBranch ?? "main"
                            }
                        } label: {
                            LabeledContent("Repository", value: repo.isEmpty ? "Scegli…" : repo)
                        }
                    }
                    HStack {
                        TextField("Branch", text: $branch)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        if loadingBranch { ProgressView() }
                    }
                } header: { Text("Destinazione") } footer: {
                    Text("Il branch diventa una copia esatta del progetto (i file che non sono nel progetto vengono rimossi dal branch con un nuovo commit; la storia precedente resta). Vengono caricati solo i file cambiati.")
                }

                Section("Avvio") {
                    Picker("Evento", selection: $trigger) {
                        ForEach(CloudTrigger.allCases) { Text($0.label).tag($0) }
                    }
                    if trigger == .auto {
                        Text(workflow.supportsDispatch ? "Il workflow dichiara workflow_dispatch: verrà avviato direttamente."
                             : "Il workflow non dichiara workflow_dispatch: verrà avviato dal push del commit.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if usesDispatch && !workflow.supportsDispatch {
                        Label("Il workflow non dichiara 'on: workflow_dispatch': GitHub rifiuterà l'avvio.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if !usesDispatch {
                        if workflow.triggers["push"] == nil {
                            Label("Il workflow non dichiara 'on: push': il commit non lo avvierà.", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        } else if let cfg = workflow.triggers["push"], !branch.isEmpty,
                                  !FilterPattern.triggerMatches(config: cfg, branch: branch, isTag: false) {
                            Label("I filtri di on.push escludono il branch '\(branch)'.", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                if usesDispatch && !workflow.dispatchInputs.isEmpty {
                    Section("Input") { DispatchInputsForm(inputs: workflow.dispatchInputs, values: $inputs) }
                }
                Section("Commit") {
                    TextField("Messaggio", text: $commitMessage, axis: .vertical)
                }
                Section {
                    Toggle("Copia secrets e variabili dell'app nel repository", isOn: $syncSecrets)
                        .disabled(settings.localSecrets.isEmpty && settings.localVariables.isEmpty)
                } footer: {
                    Text("\(settings.localSecrets.count) secrets e \(settings.localVariables.count) variabili configurati in Impostazioni. I secrets vengono cifrati sul dispositivo (sealed box) prima dell'invio, come richiesto da GitHub.")
                }
                if !macJobs.isEmpty {
                    Section {
                        Label("Job macOS (Xcode) eseguiti sui Mac di GitHub: \(macJobs.joined(separator: ", ")).", systemImage: "apple.logo")
                            .font(.caption)
                    }
                }
            }
        }
        .navigationTitle("Esegui su GitHub")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Avvia") { start() }
                    .disabled(api == nil || repo.isEmpty || branch.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            api = GitHubAPI.stored
            if repo.isEmpty { repo = project.githubRepo ?? "" }
            if branch.isEmpty { branch = project.githubBranch ?? "" }
            if commitMessage.isEmpty { commitMessage = "ActionsRunner: \(workflow.name)" }
            inputs = DispatchInputsForm.defaults(workflow.dispatchInputs)
        }
        .task(id: repo) {
            guard !repo.isEmpty, branch.isEmpty, let api else { return }
            loadingBranch = true
            defer { loadingBranch = false }
            if let r = try? await GitHubActions(api: api, repo: repo).repository() { branch = r.defaultBranch ?? "main" }
        }
    }

    private func start() {
        guard let api else { return }
        let b = branch.trimmingCharacters(in: .whitespaces)
        var p = project
        p.githubRepo = repo
        p.githubBranch = b
        store.update(p)
        let declared = Set(workflow.dispatchInputs.map(\.name))
        let req = CloudRunRequest(
            projectId: project.id, projectURL: project.repoURL, repo: repo, branch: b,
            workflowPath: workflow.path, workflowFile: workflow.fileName, title: workflow.name,
            trigger: trigger, inputs: usesDispatch ? inputs.filter { declared.contains($0.key) } : [:],
            commitMessage: commitMessage.isEmpty ? "ActionsRunner: \(workflow.name)" : commitMessage,
            syncSecrets: syncSecrets, secrets: settings.localSecrets, variables: settings.localVariables)
        let model = runs.startCloud(req, api: api)
        onStart(model)
    }
}

// MARK: - Run su GitHub

extension CloudRunModel: Hashable {
    static func == (a: CloudRunModel, b: CloudRunModel) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct CloudRunView: View {
    let model: CloudRunModel
    @Environment(RunCenter.self) private var runs
    @State private var actionError: String?
    @State private var busy = false
    @State private var showSetup = false

    var body: some View {
        List {
            Section {
                HStack(alignment: .top) {
                    StatusIcon(status: model.status, conclusion: model.conclusion, size: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.run?.displayTitle ?? model.title).font(.headline)
                        Text("\(model.repo) · \(model.branch)").font(.caption).foregroundStyle(.secondary)
                        if let r = model.run {
                            Text("#\(r.runNumber)\((r.runAttempt ?? 1) > 1 ? " (tentativo \(r.runAttempt ?? 1))" : "") · \(r.event) · \(r.headSha.prefix(7))")
                                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let r = model.run, let s = GHDate.parse(r.runStartedAt ?? r.createdAt) {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            let end = r.isCompleted ? (GHDate.parse(r.updatedAt) ?? Date()) : Date()
                            Text(Format.duration(end.timeIntervalSince(s))).font(.caption.monospacedDigit())
                        }
                    }
                }
                if model.phase != .running && model.phase != .finished {
                    Text(model.phase.label).font(.callout)
                        .foregroundStyle(isFailed ? Color.red : Color.primary)
                }
                if let p = model.uploadProgress { ProgressView(value: p) }
                if model.run?.status == "queued" || model.run?.status == "waiting" {
                    Text("In coda: in attesa di un runner di GitHub…").font(.caption).foregroundStyle(.secondary)
                }
                if let e = model.transientError { Label(e, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.orange) }
                if let c = model.conclusion, model.status == .completed {
                    Text(c.label).font(.callout.bold()).foregroundStyle(c == .success ? .green : (c == .cancelled || c == .skipped ? .secondary : .red))
                }
            }

            Section {
                if model.runId != nil, model.run?.isCompleted == false {
                    Button(role: .destructive) { act { try await runs.engine(for: model)?.cancelRun(force: model.cancelRequested) } } label: {
                        Label(model.cancelRequested ? "Forza l'annullamento" : "Annulla la run", systemImage: "stop.fill")
                    }
                    .disabled(busy)
                }
                if model.run?.isCompleted == true {
                    Menu {
                        Button("Riesegui tutti i job") { act { try await runs.engine(for: model)?.rerun(failedOnly: false, debug: false) } }
                        Button("Riesegui i job falliti") { act { try await runs.engine(for: model)?.rerun(failedOnly: true, debug: false) } }
                        Button("Riesegui con log di debug") { act { try await runs.engine(for: model)?.rerun(failedOnly: false, debug: true) } }
                    } label: { Label("Riesegui", systemImage: "arrow.clockwise") }
                    .disabled(busy)
                }
                if let url = model.webURL {
                    Link(destination: url) { Label("Apri su GitHub", systemImage: "safari") }
                }
            }

            if !model.setupLog.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showSetup) {
                        ForEach(Array(model.setupLog.enumerated()), id: \.offset) { _, l in
                            Text(l).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    } label: { Text("Preparazione (\(model.setupLog.count))") }
                }
            }

            if !model.jobs.isEmpty {
                Section("Job (\(model.jobs.count))") {
                    ForEach(model.jobs) { j in
                        NavigationLink { CloudJobView(job: j) } label: { CloudJobRow(job: j) }
                    }
                }
            }

            let annotations = model.jobs.flatMap { j in j.annotations.map { (j.job.name, $0) } }
            if !annotations.isEmpty {
                Section("Annotazioni (\(annotations.count))") {
                    ForEach(Array(annotations.enumerated()), id: \.offset) { _, pair in
                        AnnotationRow(level: pair.1.annotationLevel ?? "notice", title: pair.1.title, message: pair.1.message ?? "",
                                      location: [pair.0, pair.1.path, pair.1.startLine.map { "riga \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    }
                }
            }

            if !model.artifacts.isEmpty {
                Section("Artifact (\(model.artifacts.count))") {
                    ForEach(model.artifacts) { a in CloudArtifactRow(model: model, artifact: a) }
                }
            }
        }
        .navigationTitle("Run su GitHub")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { runs.refreshCloud(model) }
        .onAppear {
            runs.refreshCloud(model)
            if case .failed = model.phase { showSetup = true }
            if model.runId == nil { showSetup = true }
        }
        .alert("Operazione non riuscita", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
    }

    private var isFailed: Bool {
        if case .failed = model.phase { return true }
        return false
    }

    private func act(_ op: @escaping () async throws -> Void) {
        Task {
            busy = true
            defer { busy = false }
            do { try await op() } catch { actionError = error.localizedDescription }
        }
    }
}

struct CloudJobRow: View {
    let job: CloudJobModel
    var body: some View {
        HStack {
            StatusIcon(api: job.job.status, conclusion: job.job.conclusion)
            VStack(alignment: .leading) {
                Text(job.job.name)
                if let r = job.job.runnerName, !r.isEmpty {
                    Text(r).font(.caption2).foregroundStyle(.secondary)
                } else if let l = job.job.labels, !l.isEmpty {
                    Text(l.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if job.job.startedAt != nil {
                Text(Format.apiDuration(job.job.startedAt, job.job.completedAt)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

struct CloudJobView: View {
    let job: CloudJobModel
    @State private var expanded: Set<Int> = []
    @State private var showFull = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                logStateBanner.padding(.horizontal).padding(.bottom, 6)
                let steps = job.job.steps ?? []
                if steps.isEmpty || showFull {
                    LogLinesView(lines: job.fullLog).padding(.horizontal)
                } else {
                    ForEach(steps, id: \.number) { step in
                        VStack(alignment: .leading, spacing: 0) {
                            Button {
                                if expanded.contains(step.number) { expanded.remove(step.number) } else { expanded.insert(step.number) }
                            } label: {
                                HStack {
                                    Image(systemName: expanded.contains(step.number) ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 12)
                                    StatusIcon(api: step.status, conclusion: step.conclusion, size: 14)
                                    Text(step.name).font(.subheadline).lineLimit(2).multilineTextAlignment(.leading)
                                    Spacer()
                                    if step.startedAt != nil {
                                        Text(Format.apiDuration(step.startedAt, step.completedAt)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if expanded.contains(step.number) {
                                let lines = job.stepLogs[step.number] ?? []
                                if lines.isEmpty {
                                    Text(step.status == "completed" ? "Nessuna riga di log per questo step." : "Log non ancora disponibili.")
                                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom, 8)
                                } else {
                                    LogLinesView(lines: lines).padding(.horizontal).padding(.bottom, 8)
                                }
                            }
                            Divider()
                        }
                    }
                }
                if !job.annotations.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Annotazioni").font(.caption.bold())
                        ForEach(Array(job.annotations.enumerated()), id: \.offset) { _, a in
                            AnnotationRow(level: a.annotationLevel ?? "notice", title: a.title, message: a.message ?? "",
                                          location: [a.path, a.startLine.map { "riga \($0)" }].compactMap { $0 }.joined(separator: " · "))
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(job.job.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle("Log completo del job", isOn: $showFull)
                    if !job.fullLog.isEmpty {
                        ShareLink(item: job.fullLog.map(\.text).joined(separator: "\n")) { Label("Condividi il log", systemImage: "square.and.arrow.up") }
                    }
                    if let u = job.job.htmlUrl.flatMap({ URL(string: $0) }) {
                        Link(destination: u) { Label("Apri su GitHub", systemImage: "safari") }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear {
            if let failed = job.job.steps?.first(where: { $0.conclusion == "failure" }) { expanded.insert(failed.number) }
            else if let running = job.job.steps?.last(where: { $0.status == "in_progress" }) { expanded.insert(running.number) }
        }
    }

    @ViewBuilder private var logStateBanner: some View {
        switch job.logState {
        case .none:
            if job.job.status == "queued" || job.job.status == "waiting" {
                Text("Il job è in attesa di un runner.").font(.caption).foregroundStyle(.secondary)
            } else if !job.job.isCompleted {
                Text("I log compaiono durante l'esecuzione (aggiornati ogni 15 s) o al termine del job.").font(.caption).foregroundStyle(.secondary)
            }
        case .loading:
            HStack { ProgressView().controlSize(.small); Text("Caricamento dei log…").font(.caption) }
        case .partial:
            Text("Log parziali: il job è ancora in esecuzione.").font(.caption).foregroundStyle(.secondary)
        case .complete:
            EmptyView()
        case .unavailable(let m):
            Label("Log non disponibili: \(m)", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
    }
}

// MARK: - Artifact

struct CloudArtifactRow: View {
    let model: CloudRunModel
    let artifact: GHArtifact
    @Environment(RunCenter.self) private var runs
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(artifact.name, systemImage: "doc.zipper")
                Spacer()
                Text(Format.bytes(Int64(artifact.sizeInBytes))).font(.caption).foregroundStyle(.secondary)
            }
            if artifact.expired {
                Text("Scaduto: GitHub non lo conserva più").font(.caption).foregroundStyle(.secondary)
            } else if let file = model.artifactFiles[artifact.id] {
                HStack(spacing: 16) {
                    ShareLink(item: file) { Label("Zip", systemImage: "square.and.arrow.up") }
                    NavigationLink { ArtifactContentsView(zip: file, title: artifact.name) } label: {
                        Label("Contenuto", systemImage: "folder")
                    }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            } else if model.downloading.contains(artifact.id) {
                HStack { ProgressView().controlSize(.small); Text("Download…").font(.caption) }
            } else {
                Button {
                    Task {
                        do { _ = try await runs.engine(for: model)?.download(artifact) } catch { self.error = error.localizedDescription }
                    }
                } label: { Label("Scarica", systemImage: "arrow.down.circle") }
                .font(.caption)
                .buttonStyle(.borderless)
            }
            if let error { Text(error).font(.caption2).foregroundStyle(.red) }
        }
    }
}

/// Contenuto di un artifact scaricato (estratto una sola volta), con condivisione dei singoli file (es. .ipa).
struct ArtifactContentsView: View {
    let zip: URL
    let title: String
    @State private var files: [(relative: String, url: URL)] = []
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(files, id: \.relative) { f in
                HStack {
                    Image(systemName: f.relative.hasSuffix(".ipa") ? "app.badge" : "doc")
                    VStack(alignment: .leading) {
                        Text(f.relative).font(.callout).lineLimit(2)
                        let size = ((try? FileManager.default.attributesOfItem(atPath: f.url.path))?[.size] as? NSNumber)?.int64Value ?? 0
                        Text(Format.bytes(size)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShareLink(item: f.url) { Image(systemName: "square.and.arrow.up") }.buttonStyle(.borderless)
                }
            }
        }
        .navigationTitle(title)
        .task {
            let dir = zip.deletingPathExtension()
            do {
                if !FileManager.default.fileExists(atPath: dir.path) {
                    try await Task.detached { try ZipUtil.unzip(zip, to: dir) }.value
                }
                files = ZipUtil.listFiles(in: dir)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
