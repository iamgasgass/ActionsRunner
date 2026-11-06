import SwiftUI

// MARK: - Account

struct GitHubAccountView: View {
    @State private var token = ""
    @State private var info: GitHubAPI.TokenInfo?
    @State private var error: String?
    @State private var checking = false
    @State private var hasToken = GitHubAPI.stored != nil
    @State private var confirmRemove = false

    static let classicTokenURL = URL(string: "https://github.com/settings/tokens/new?scopes=repo,workflow&description=ActionsRunner%20iOS")!
    static let fineGrainedURL = URL(string: "https://github.com/settings/personal-access-tokens/new")!

    var body: some View {
        GlassScreen(spacing: 16) {
            if hasToken {
                VStack(alignment: .leading, spacing: 16) {
                    GlassSectionHeading(title: "Account collegato", subtitle: "Token salvato nel portachiavi di questo iPhone.",
                                        symbol: "person.crop.circle.badge.checkmark")
                    if checking {
                        HStack(spacing: 10) { ProgressView().tint(.white); Text("Verifica…").font(.subheadline) }
                    }
                    if let info {
                        GlassDetailRow(title: "Utente", value: info.user.login, symbol: "person")
                        GlassDivider()
                        if let scopes = info.scopes {
                            GlassDetailRow(title: "Scope", value: scopes.isEmpty ? "nessuno" : scopes.joined(separator: ", "), symbol: "checklist")
                            let missing = ["repo", "workflow"].filter { !scopes.contains($0) }
                            if !missing.isEmpty {
                                Label("Mancano gli scope: \(missing.joined(separator: ", ")). Senza 'workflow' GitHub rifiuta il caricamento dei file in .github/workflows.",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            GlassDetailRow(title: "Tipo", value: "fine-grained", symbol: "key.horizontal")
                        }
                        if let r = info.rateRemaining {
                            GlassDivider()
                            GlassDetailRow(title: "Richieste API rimaste (ora)", value: "\(r)", symbol: "gauge.with.dots.needle.33percent")
                        }
                        GlassStatusPill(title: "Verificato", symbol: "checkmark.seal.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button { Task { await verify() } } label: {
                        Label("Verifica di nuovo", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(LiquidGlassButtonStyle())
                    .disabled(checking)
                    Button(role: .destructive) { confirmRemove = true } label: {
                        Label("Rimuovi token", systemImage: "key.slash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                .glassSection()
            }

            VStack(alignment: .leading, spacing: 12) {
                GlassSectionHeading(title: hasToken ? "Nuovo token" : "Token di accesso personale",
                                    subtitle: "Viene inviato soltanto a api.github.com.", symbol: "key.fill")
                GlassFieldLabel("Token")
                GlassTextFieldSurface {
                    SecureField("ghp_… oppure github_pat_…", text: $token)
                        .font(.system(.subheadline, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Button {
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
                } label: {
                    HStack(spacing: 9) {
                        if checking { ProgressView().tint(.white) }
                        Text(hasToken ? "Sostituisci e verifica" : "Salva e verifica")
                    }
                }
                .buttonStyle(LiquidGlassButtonStyle(prominent: true))
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checking)
                .padding(.top, 4)
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            .glassSection()

            VStack(alignment: .leading, spacing: 14) {
                GlassSectionHeading(title: "Come crearlo", subtitle: "Si apre GitHub in Safari.", symbol: "questionmark.circle")
                Link(destination: GitHubAccountView.classicTokenURL) {
                    Label("Token classic: repo + workflow", systemImage: "key")
                }
                .buttonStyle(LiquidGlassButtonStyle(prominent: !hasToken))
                Link(destination: GitHubAccountView.fineGrainedURL) {
                    Label("Token fine-grained", systemImage: "key.horizontal")
                }
                .buttonStyle(LiquidGlassButtonStyle())
                Text("Per un token fine-grained concedi sui repository scelti: Contents, Actions, Workflows, Secrets e Variables in lettura e scrittura (Administration in scrittura per creare repository dall'app).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .glassSection()
        }
        .navigationTitle("Account GitHub")
        .navigationBarTitleDisplayMode(.inline)
        .task { if hasToken && info == nil { await verify() } }
        .confirmationDialog("Rimuovere il token?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Rimuovi token", role: .destructive) {
                Keychain.set(nil, for: GitHubAPI.tokenAccount)
                hasToken = false
                info = nil
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("L'app non potrà più avviare né seguire le run finché non colleghi un nuovo token.")
        }
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
        GlassScreen(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                GlassSectionHeading(title: "Nuovo repository",
                                    subtitle: "Consigliato: un repository dedicato, così il branch contiene esattamente il progetto importato.",
                                    symbol: "plus.rectangle.on.folder")
                GlassFieldLabel("Nome")
                GlassTextFieldSurface {
                    TextField("nome-repository", text: $newName)
                        .font(.system(.subheadline, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Toggle(isOn: $newPrivate) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Privato").font(.subheadline.weight(.semibold))
                        Text(newPrivate ? "Visibile solo a te" : "Visibile a tutti")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tint(.white)
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
                    HStack(spacing: 9) {
                        if creating { ProgressView().tint(.white) } else { Image(systemName: "plus") }
                        Text(creating ? "Creazione…" : "Crea repository")
                    }
                }
                .buttonStyle(LiquidGlassButtonStyle(prominent: true))
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || creating)
            }
            .glassSection()

            if let error { GlassErrorText(message: error) }

            GlassListHeader(title: "I tuoi repository", count: loading ? nil : filtered.count, symbol: "folder.fill")

            if loading {
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("Caricamento…").font(.subheadline)
                }
                .glassSection(cornerRadius: 24)
            }

            LazyVStack(spacing: 12) {
                ForEach(filtered) { r in
                    Button {
                        onSelect(r)
                        dismiss()
                    } label: {
                        HStack(spacing: 14) {
                            GlassIconBadge(symbol: r.private ? "lock.fill" : "globe", size: 44)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(r.fullName)
                                    .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                if let p = GHDate.parse(r.pushedAt) {
                                    Text("aggiornato \(Format.relative.localizedString(for: p, relativeTo: Date()))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 4)
                            if r.permissions?.push == false {
                                Text("sola lettura").font(.caption2).foregroundStyle(.orange)
                            } else {
                                GlassChevron()
                            }
                        }
                        .glassRow()
                    }
                    .buttonStyle(.plain)
                    .disabled(r.permissions?.push == false)
                }
            }
        }
        .searchable(text: $search, prompt: "Cerca")
        .navigationTitle("Repository")
        .navigationBarTitleDisplayMode(.inline)
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
        GlassScreen(spacing: 16) {
            if api == nil {
                HStack(alignment: .top, spacing: 13) {
                    GlassIconBadge(symbol: "person.crop.circle.badge.exclamationmark", size: 46)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Collega GitHub per iniziare")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                        Text("Serve un token per eseguire il workflow sui runner di GitHub.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .liquidGlassCard(cornerRadius: 24)

                NavigationLink { GitHubAccountView() } label: {
                    Label("Configura il token", systemImage: "key.fill")
                }
                .buttonStyle(LiquidGlassButtonStyle(prominent: true))
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    GlassSectionHeading(title: "Destinazione", subtitle: "Repository e branch su cui caricare il progetto.", symbol: "arrow.triangle.branch")
                    GlassFieldLabel("Repository")
                    if let api {
                        NavigationLink {
                            RepoPickerView(api: api, suggestedName: Project.sanitizedRepoName(project.name)) { r in
                                repo = r.fullName
                                branch = r.defaultBranch ?? "main"
                            }
                        } label: {
                            HStack {
                                Text(repo.isEmpty ? "Scegli…" : repo)
                                    .font(.system(.subheadline, design: .monospaced, weight: .medium))
                                    .foregroundStyle(repo.isEmpty ? Color.secondary : Color.primary)
                                Spacer()
                                GlassChevron()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .liquidGlassCard(cornerRadius: 17, borderOpacity: 0.11)
                        }
                        .buttonStyle(.plain)
                    }
                    GlassFieldLabel("Branch")
                    GlassTextFieldSurface {
                        HStack {
                            TextField("main", text: $branch)
                                .font(.system(.subheadline, design: .monospaced))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            if loadingBranch { ProgressView().tint(.white) }
                        }
                    }
                    Text("Il branch diventa una copia esatta del progetto (i file che non sono nel progetto vengono rimossi dal branch con un nuovo commit; la storia precedente resta). Vengono caricati solo i file cambiati.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .glassSection()

                VStack(alignment: .leading, spacing: 12) {
                    GlassSectionHeading(title: "Avvio", subtitle: "Come GitHub fa partire il workflow.", symbol: "bolt.fill")
                    GlassFieldLabel("Evento")
                    GlassTextFieldSurface {
                        Picker("Evento", selection: $trigger) {
                            ForEach(CloudTrigger.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .tint(.white)
                    }
                    if trigger == .auto {
                        Text(workflow.supportsDispatch ? "Il workflow dichiara workflow_dispatch: verrà avviato direttamente."
                             : "Il workflow non dichiara workflow_dispatch: verrà avviato dal push del commit.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if usesDispatch && !workflow.supportsDispatch {
                        warning("Il workflow non dichiara 'on: workflow_dispatch': GitHub rifiuterà l'avvio.")
                    }
                    if !usesDispatch {
                        if workflow.triggers["push"] == nil {
                            warning("Il workflow non dichiara 'on: push': il commit non lo avvierà.")
                        } else if let cfg = workflow.triggers["push"], !branch.isEmpty,
                                  !FilterPattern.triggerMatches(config: cfg, branch: branch, isTag: false) {
                            warning("I filtri di on.push escludono il branch '\(branch)'.")
                        }
                    }
                    if usesDispatch && !workflow.dispatchInputs.isEmpty {
                        GlassDivider()
                        DispatchInputsForm(inputs: workflow.dispatchInputs, values: $inputs)
                    }
                }
                .glassSection()

                VStack(alignment: .leading, spacing: 12) {
                    GlassSectionHeading(title: "Commit", subtitle: "Messaggio del commit creato su GitHub.", symbol: "text.bubble")
                    GlassTextFieldSurface {
                        TextField("Messaggio", text: $commitMessage, axis: .vertical)
                            .font(.subheadline)
                            .lineLimit(1...4)
                    }
                }
                .glassSection()

                VStack(alignment: .leading, spacing: 12) {
                    GlassSectionHeading(title: "Secrets e variabili",
                                        subtitle: "\(settings.localSecrets.count) secrets e \(settings.localVariables.count) variabili configurati nell'app.",
                                        symbol: "lock.fill")
                    Toggle(isOn: $syncSecrets) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Copia nel repository").font(.subheadline.weight(.semibold))
                            Text("I secrets vengono cifrati sul dispositivo (sealed box) prima dell'invio, come richiesto da GitHub.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(.white)
                    .disabled(settings.localSecrets.isEmpty && settings.localVariables.isEmpty)
                }
                .glassSection()

                if !macJobs.isEmpty {
                    HStack(alignment: .top, spacing: 13) {
                        GlassIconBadge(symbol: "apple.logo", size: 42)
                        Text("Job macOS (Xcode) eseguiti sui Mac di GitHub: \(macJobs.joined(separator: ", ")).")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .liquidGlassCard(cornerRadius: 24)
                }

                Button { start() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill")
                        Text("Avvia su GitHub")
                    }
                }
                .buttonStyle(LiquidGlassButtonStyle(prominent: true))
                .disabled(!canStart)
            }
        }
        .navigationTitle("Esegui su GitHub")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Annulla", role: .cancel) { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Avvia") { start() }
                    .fontWeight(.semibold)
                    .disabled(!canStart)
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

    private var canStart: Bool {
        api != nil && !repo.isEmpty && !branch.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
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
        GlassScreen {
            header

            if model.runId != nil || model.webURL != nil {
                VStack(alignment: .leading, spacing: 12) {
                    if model.runId != nil, model.run?.isCompleted == false {
                        Button(role: .destructive) { act { try await runs.engine(for: model)?.cancelRun(force: model.cancelRequested) } } label: {
                            Label(model.cancelRequested ? "Forza l'annullamento" : "Annulla la run", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .disabled(busy)
                    }
                    if model.run?.isCompleted == true {
                        Menu {
                            Button("Riesegui tutti i job") { act { try await runs.engine(for: model)?.rerun(failedOnly: false, debug: false) } }
                            Button("Riesegui i job falliti") { act { try await runs.engine(for: model)?.rerun(failedOnly: true, debug: false) } }
                            Button("Riesegui con log di debug") { act { try await runs.engine(for: model)?.rerun(failedOnly: false, debug: true) } }
                        } label: {
                            HStack(spacing: 10) {
                                if busy { ProgressView().tint(.white) } else { Image(systemName: "arrow.clockwise") }
                                Text("Riesegui")
                            }
                        }
                        .menuStyle(.button)
                        .buttonStyle(LiquidGlassButtonStyle(prominent: true))
                        .disabled(busy)
                    }
                    if let url = model.webURL {
                        Link(destination: url) { Label("Apri su GitHub", systemImage: "safari") }
                            .buttonStyle(LiquidGlassButtonStyle())
                    }
                }
            }

            if !model.jobs.isEmpty {
                GlassListHeader(title: "Job", count: model.jobs.count, symbol: "square.stack.3d.up.fill")
                LazyVStack(spacing: 12) {
                    ForEach(model.jobs) { j in
                        NavigationLink { CloudJobView(job: j) } label: { CloudJobRow(job: j) }
                            .buttonStyle(.plain)
                    }
                }
            }

            let annotations = model.jobs.flatMap { j in j.annotations.map { (j.job.name, $0) } }
            if !annotations.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    GlassSectionHeading(title: "Annotazioni", subtitle: "\(annotations.count) segnalazioni dai job.", symbol: "exclamationmark.bubble")
                    ForEach(Array(annotations.enumerated()), id: \.offset) { _, pair in
                        AnnotationRow(level: pair.1.annotationLevel ?? "notice", title: pair.1.title, message: pair.1.message ?? "",
                                      location: [pair.0, pair.1.path, pair.1.startLine.map { "riga \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    }
                }
                .glassSection()
            }

            if !model.artifacts.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    GlassSectionHeading(title: "Artifact", subtitle: "\(model.artifacts.count) file prodotti dalla run.", symbol: "doc.zipper")
                    ForEach(model.artifacts) { a in CloudArtifactRow(model: model, artifact: a) }
                }
                .glassSection()
            }

            if !model.setupLog.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showSetup.toggle() }
                    } label: {
                        HStack {
                            GlassSectionHeading(title: "Preparazione", subtitle: "\(model.setupLog.count) passaggi: caricamento e avvio.", symbol: "terminal")
                            Image(systemName: showSetup ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showSetup {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(model.setupLog.enumerated()), id: \.offset) { _, l in
                                Text(l)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .glassInset()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .glassSection()
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                StatusIcon(status: model.status, conclusion: model.conclusion, size: 24)
                    .frame(width: 52, height: 52)
                    .background { Circle().fill(Color.white.opacity(0.075)) }
                    .overlay { Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8) }
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.run?.displayTitle ?? model.title)
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(model.repo) · \(model.branch)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let r = model.run {
                        Text("#\(r.runNumber)\((r.runAttempt ?? 1) > 1 ? " (tentativo \(r.runAttempt ?? 1))" : "") · \(r.event) · \(r.headSha.prefix(7))")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                if let c = model.conclusion, model.status == .completed {
                    GlassStatusPill(title: c.label, symbol: c == .success ? "checkmark.circle.fill" : (c == .cancelled || c == .skipped ? "minus.circle.fill" : "xmark.circle.fill"))
                } else if model.phase == .running {
                    GlassStatusPill(title: model.run?.status == "in_progress" ? "In esecuzione" : "In coda", symbol: "circle.dotted")
                }
                if let r = model.run, let s = GHDate.parse(r.runStartedAt ?? r.createdAt) {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let end = r.isCompleted ? (GHDate.parse(r.updatedAt) ?? Date()) : Date()
                        GlassStatusPill(title: Format.duration(end.timeIntervalSince(s)), symbol: "timer")
                    }
                }
            }

            if model.phase != .running && model.phase != .finished {
                Text(model.phase.label)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(isFailed ? Color.red : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let p = model.uploadProgress {
                ProgressView(value: p).tint(.white)
            }
            if model.run?.status == "queued" || model.run?.status == "waiting" {
                Text("In coda: in attesa di un runner di GitHub…").font(.footnote).foregroundStyle(.secondary)
            }
            if let e = model.transientError {
                Label(e, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(cornerRadius: 30, borderOpacity: 0.18)
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
        HStack(spacing: 14) {
            StatusIcon(api: job.job.status, conclusion: job.job.conclusion, size: 18)
                .frame(width: 44, height: 44)
                .background { Circle().fill(Color.white.opacity(0.075)) }
                .overlay { Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8) }
            VStack(alignment: .leading, spacing: 4) {
                Text(job.job.name)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let r = job.job.runnerName, !r.isEmpty {
                    Text(r).font(.caption2).foregroundStyle(.secondary)
                } else if let l = job.job.labels, !l.isEmpty {
                    Text(l.joined(separator: ", ")).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if job.job.startedAt != nil {
                Text(Format.apiDuration(job.job.startedAt, job.job.completedAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GlassChevron()
        }
        .glassRow()
    }
}

struct CloudJobView: View {
    let job: CloudJobModel
    @State private var expanded: Set<Int> = []
    @State private var showFull = false

    var body: some View {
        GlassScreen(spacing: 12) {
            logStateBanner

            let steps = job.job.steps ?? []
            if steps.isEmpty || showFull {
                LogLinesView(lines: job.fullLog)
                    .glassInset()
            } else {
                ForEach(steps, id: \.number) { step in
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if expanded.contains(step.number) { expanded.remove(step.number) } else { expanded.insert(step.number) }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                StatusIcon(api: step.status, conclusion: step.conclusion, size: 15)
                                Text(step.name)
                                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 4)
                                if step.startedAt != nil {
                                    Text(Format.apiDuration(step.startedAt, step.completedAt))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Image(systemName: expanded.contains(step.number) ? "chevron.up" : "chevron.down")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if expanded.contains(step.number) {
                            let lines = job.stepLogs[step.number] ?? []
                            if lines.isEmpty {
                                Text(step.status == "completed" ? "Nessuna riga di log per questo step." : "Log non ancora disponibili.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                LogLinesView(lines: lines)
                                    .glassInset()
                            }
                        }
                    }
                    .glassRow()
                }
            }

            if !job.annotations.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    GlassSectionHeading(title: "Annotazioni", subtitle: nil, symbol: "exclamationmark.bubble")
                    ForEach(Array(job.annotations.enumerated()), id: \.offset) { _, a in
                        AnnotationRow(level: a.annotationLevel ?? "notice", title: a.title, message: a.message ?? "",
                                      location: [a.path, a.startLine.map { "riga \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    }
                }
                .glassSection()
            }
        }
        .navigationTitle(job.job.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Log completo del job", isOn: $showFull)
                    if !job.fullLog.isEmpty {
                        ShareLink(item: job.fullLog.map(\.text).joined(separator: "\n")) { Label("Condividi il log", systemImage: "square.and.arrow.up") }
                    }
                    if let u = job.job.htmlUrl.flatMap({ URL(string: $0) }) {
                        Link(destination: u) { Label("Apri su GitHub", systemImage: "safari") }
                    }
                } label: { Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)) }
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
                banner("Il job è in attesa di un runner.", symbol: "hourglass")
            } else if !job.job.isCompleted {
                banner("I log compaiono durante l'esecuzione (aggiornati ogni 15 s) o al termine del job.", symbol: "clock.arrow.circlepath")
            }
        case .loading:
            HStack(spacing: 10) {
                ProgressView().tint(.white)
                Text("Caricamento dei log…").font(.subheadline)
            }
            .glassInset()
        case .partial:
            banner("Log parziali: il job è ancora in esecuzione.", symbol: "dot.radiowaves.left.and.right")
        case .complete:
            EmptyView()
        case .unavailable(let m):
            Label("Log non disponibili: \(m)", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(.orange)
                .glassInset()
        }
    }

    private func banner(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .glassInset()
    }
}

// MARK: - Artifact

struct CloudArtifactRow: View {
    let model: CloudRunModel
    let artifact: GHArtifact
    @Environment(RunCenter.self) private var runs
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                GlassIconBadge(symbol: "doc.zipper", size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(artifact.name)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .lineLimit(2)
                    Text(artifact.expired ? "Scaduto: GitHub non lo conserva più" : Format.bytes(Int64(artifact.sizeInBytes)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if !artifact.expired {
                if let file = model.artifactFiles[artifact.id] {
                    HStack(spacing: 10) {
                        ShareLink(item: file) { Label("Zip", systemImage: "square.and.arrow.up") }
                            .buttonStyle(LiquidGlassButtonStyle())
                        NavigationLink { ArtifactContentsView(zip: file, title: artifact.name) } label: {
                            Label("Contenuto", systemImage: "folder")
                        }
                        .buttonStyle(LiquidGlassButtonStyle(prominent: true))
                    }
                } else {
                    Button {
                        Task {
                            do { _ = try await runs.engine(for: model)?.download(artifact) } catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        HStack(spacing: 9) {
                            if model.downloading.contains(artifact.id) { ProgressView().tint(.white) } else { Image(systemName: "arrow.down.circle") }
                            Text(model.downloading.contains(artifact.id) ? "Download…" : "Scarica")
                        }
                    }
                    .buttonStyle(LiquidGlassButtonStyle(prominent: true))
                    .disabled(model.downloading.contains(artifact.id))
                }
            }
            if let error { Text(error).font(.caption2).foregroundStyle(.red) }
        }
        .glassInset()
    }
}

/// Contenuto di un artifact scaricato (estratto una sola volta), con condivisione dei singoli file (es. .ipa).
struct ArtifactContentsView: View {
    let zip: URL
    let title: String
    @State private var files: [(relative: String, url: URL)] = []
    @State private var error: String?

    var body: some View {
        GlassScreen(spacing: 12) {
            if let error { GlassErrorText(message: error) }
            GlassListHeader(title: "File", count: files.count, symbol: "doc.on.doc.fill")
            LazyVStack(spacing: 10) {
                ForEach(files, id: \.relative) { f in
                    HStack(spacing: 12) {
                        GlassIconBadge(symbol: f.relative.hasSuffix(".ipa") ? "app.badge" : "doc", size: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(f.relative)
                                .font(.system(.subheadline, design: .rounded, weight: .medium))
                                .lineLimit(2)
                            let size = ((try? FileManager.default.attributesOfItem(atPath: f.url.path))?[.size] as? NSNumber)?.int64Value ?? 0
                            Text(Format.bytes(size)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        ShareLink(item: f.url) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background { Circle().fill(Color.white.opacity(0.075)) }
                                .overlay { Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8) }
                        }
                        .buttonStyle(.plain)
                    }
                    .glassRow()
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
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
