import Foundation
import Observation

/// Carica il contenuto della repo importata su GitHub con la Git Data API (blob → tree → commit → ref),
/// senza bisogno di git sul dispositivo.
struct RepoPusher {
    let api: GitHubAPI
    let owner: String
    let repo: String
    let progress: (Double, String) -> Void

    struct PushResult {
        let commitSHA: String
        let branch: String
        let fileCount: Int
    }

    static let inlineLimit = 256 * 1024
    static let maxFileSize = 100 * 1024 * 1024

    func push(from root: URL, branch requestedBranch: String?, message: String, defaultBranch: String) async throws -> PushResult {
        let fm = FileManager.default
        let branch = (requestedBranch?.isEmpty == false ? requestedBranch! : defaultBranch)

        // 1. elenco file (esclusa .git)
        var files: [(rel: String, url: URL, mode: String)] = []
        for f in ZipUtil.listFiles(in: root) {
            if f.relative == ".git" || f.relative.hasPrefix(".git/") { continue }
            let attrs = try? fm.attributesOfItem(atPath: f.url.path)
            let isLink = (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink
            let perms = (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            let mode = isLink ? "120000" : ((perms & 0o111) != 0 || f.relative.hasSuffix(".sh") && (perms & 0o100) != 0 ? "100755" : "100644")
            files.append((f.relative, f.url, mode))
        }
        guard !files.isEmpty else { throw GitHubError(status: 0, message: "La repository importata non contiene file") }
        progress(0.02, "\(files.count) file da caricare su \(owner)/\(repo)")

        // 2. commit padre (se il branch esiste)
        var parentSHA: String? = nil
        if let ref = try await api.ref(owner, repo, branch: branch) {
            parentSHA = ref.object.sha
        } else if let defRef = try await api.ref(owner, repo, branch: defaultBranch) {
            parentSHA = defRef.object.sha
        }

        // 3. blob/entries
        var entries: [[String: Any]] = []
        var processed = 0
        var blobsToCreate: [(Int, URL)] = []
        for (i, f) in files.enumerated() {
            let size = ((try? fm.attributesOfItem(atPath: f.url.path))?[.size] as? NSNumber)?.intValue ?? 0
            if size > RepoPusher.maxFileSize {
                throw GitHubError(status: 0, message: "\(f.rel) supera il limite di 100 MB di GitHub")
            }
            var entry: [String: Any] = ["path": f.rel, "mode": f.mode, "type": "blob"]
            if f.mode == "120000" {
                entry["content"] = (try? fm.destinationOfSymbolicLink(atPath: f.url.path)) ?? ""
            } else if size <= RepoPusher.inlineLimit, let data = try? Data(contentsOf: f.url),
                      !data.contains(0), let text = String(data: data, encoding: .utf8) {
                entry["content"] = text
            } else {
                blobsToCreate.append((i, f.url))
            }
            entries.append(entry)
        }

        // blob binari in parallelo (limitato)
        let total = Double(blobsToCreate.count + 1)
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var iterator = blobsToCreate.makeIterator()
            var running = 0
            func addNext() -> Bool {
                guard let item = iterator.next() else { return false }
                let idx = item.0
                let url = item.1
                group.addTask {
                    let data = try Data(contentsOf: url)
                    let blob = try await self.api.post(GHSha.self, "repos/\(self.owner)/\(self.repo)/git/blobs",
                                                       body: ["content": data.base64EncodedString(), "encoding": "base64"])
                    return (idx, blob.sha)
                }
                return true
            }
            while running < 4, addNext() { running += 1 }
            while let pair = try await group.next() {
                let idx = pair.0
                let sha = pair.1
                entries[idx]["sha"] = sha
                processed += 1
                progress(0.05 + 0.75 * Double(processed) / total, "Blob \(processed)/\(blobsToCreate.count): \(files[idx].rel)")
                if !addNext() { running -= 1 }
            }
        }

        // 4. tree a blocchi (base_tree concatenato)
        var treeSHA: String? = nil
        var chunk: [[String: Any]] = []
        var chunkBytes = 0
        var chunksDone = 0
        func flushChunk() async throws {
            guard !chunk.isEmpty else { return }
            var body: [String: Any] = ["tree": chunk]
            if let t = treeSHA { body["base_tree"] = t }
            let tree = try await api.post(GHSha.self, "repos/\(owner)/\(repo)/git/trees", body: body)
            treeSHA = tree.sha
            chunksDone += 1
            progress(0.8 + 0.12 * min(1, Double(chunksDone * 400) / Double(max(entries.count, 1))), "Albero Git: \(chunksDone) blocchi")
            chunk.removeAll()
            chunkBytes = 0
        }
        for e in entries {
            chunk.append(e)
            chunkBytes += (e["content"] as? String)?.utf8.count ?? 64
            if chunk.count >= 400 || chunkBytes > 6_000_000 { try await flushChunk() }
        }
        try await flushChunk()
        guard let tree = treeSHA else { throw GitHubError(status: 0, message: "Creazione dell'albero fallita") }

        // 5. commit
        progress(0.94, "Creazione del commit")
        var commitBody: [String: Any] = ["message": message, "tree": tree]
        if let p = parentSHA { commitBody["parents"] = [p] }
        let commit = try await api.post(GHCommit.self, "repos/\(owner)/\(repo)/git/commits", body: commitBody)

        // 6. aggiornamento/creazione del ref
        progress(0.97, "Aggiornamento di refs/heads/\(branch)")
        if try await api.ref(owner, repo, branch: branch) != nil {
            _ = try await api.patch(GHRef.self, "repos/\(owner)/\(repo)/git/refs/heads/\(branch)", body: ["sha": commit.sha, "force": true])
        } else {
            _ = try await api.post(GHRef.self, "repos/\(owner)/\(repo)/git/refs", body: ["ref": "refs/heads/\(branch)", "sha": commit.sha])
        }
        progress(1, "Push completato: \(commit.sha.prefix(7))")
        return PushResult(commitSHA: commit.sha, branch: branch, fileCount: files.count)
    }
}

/// Esecuzione fedele: carica la repo su GitHub, avvia il workflow sui runner reali e ne segue l'esecuzione.
@Observable
final class CloudRunSession: Identifiable {
    enum Phase: Equatable {
        case idle, preparing, uploading, syncingSecrets, triggering, waitingForRun, running, completed, failed(String)
        var label: String {
            switch self {
            case .idle: return "Pronto"
            case .preparing: return "Preparazione del repository"
            case .uploading: return "Caricamento dei file"
            case .syncingSecrets: return "Sincronizzazione secrets e variabili"
            case .triggering: return "Avvio del workflow"
            case .waitingForRun: return "In attesa che GitHub avvii la run"
            case .running: return "In esecuzione sui runner GitHub"
            case .completed: return "Completato"
            case .failed(let m): return "Errore: \(m)"
            }
        }
    }

    enum TriggerMode: String, CaseIterable, Identifiable {
        case automatic, push, dispatch
        var id: String { rawValue }
        var label: String {
            switch self {
            case .automatic: return "Automatico"
            case .push: return "Solo push"
            case .dispatch: return "workflow_dispatch"
            }
        }
    }

    let id = UUID()
    var phase: Phase = .idle
    var progress: Double = 0
    var message = ""
    var owner = ""
    var repo = ""
    var commitSHA: String?
    var run: GHWorkflowRun?
    var jobs: [GHJob] = []
    var logs: [Int: String] = [:]
    var annotations: [Int: [GHAnnotation]] = [:]
    var artifacts: [GHArtifact] = []
    var downloaded: [Int: URL] = [:]
    var downloading: Set<Int> = []
    var events: [String] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var api: GitHubAPI?

    var hasFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    var isActive: Bool {
        switch phase {
        case .idle, .completed, .failed: return false
        default: return true
        }
    }

    private func note(_ s: String) {
        onMain {
            self.message = s
            self.events.append("[\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))] \(s)")
        }
    }

    private func set(_ p: Phase) { onMain { self.phase = p } }

    func cancelPolling() { task?.cancel() }

    /// Avvia l'intero flusso: repo → push → secrets → trigger → monitoraggio.
    func start(project: Project, workflow: Workflow, settings: AppSettings, store: ProjectStore,
               trigger: TriggerMode, inputs: [String: String], branchOverride: String?) {
        task?.cancel()
        let token = settings.token
        let api = GitHubAPI(token: token)
        self.api = api
        task = Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.execute(api: api, project: project, workflow: workflow, settings: settings, store: store,
                                       trigger: trigger, inputs: inputs, branchOverride: branchOverride)
            } catch is CancellationError {
                self.note("Monitoraggio interrotto")
            } catch {
                self.note(error.localizedDescription)
                self.set(.failed(error.localizedDescription))
            }
        }
    }

    /// Riprende il monitoraggio di una run esistente.
    func attach(owner: String, repo: String, runId: Int, token: String) {
        task?.cancel()
        let api = GitHubAPI(token: token)
        self.api = api
        onMain { self.owner = owner; self.repo = repo }
        task = Task { [weak self] in
            guard let self = self else { return }
            do {
                let run = try await api.workflowRun(owner, repo, id: runId)
                onMain { self.run = run }
                try await self.monitor(api: api, runId: runId, onFinish: nil)
            } catch {
                self.set(.failed(error.localizedDescription))
            }
        }
    }

    private func execute(api: GitHubAPI, project: Project, workflow: Workflow, settings: AppSettings, store: ProjectStore,
                         trigger: TriggerMode, inputs: [String: String], branchOverride: String?) async throws {
        set(.preparing)
        onMain { self.progress = 0; self.jobs = []; self.logs = [:]; self.artifacts = []; self.run = nil }
        guard settings.hasToken else { throw GitHubError(status: 401, message: "Configura un token GitHub nelle Impostazioni") }

        let (user, scopes) = try await api.currentUser()
        if !scopes.isEmpty && !scopes.contains("workflow") {
            note("Attenzione: il token classic non ha lo scope 'workflow'; il caricamento di .github/workflows verrà rifiutato.")
        }
        onMain { settings.login = user.login; settings.tokenScopes = scopes }

        var proj = project
        let owner = proj.githubOwner ?? (settings.defaultOwner.isEmpty ? user.login : settings.defaultOwner)
        let repoName = proj.githubRepo ?? Project.sanitizedRepoName(settings.repoPrefix + proj.name)
        onMain { self.owner = owner; self.repo = repoName }

        // repository
        var repoInfo = try await api.repo(owner, repoName)
        if repoInfo == nil {
            guard settings.autoCreateRepo else {
                throw GitHubError(status: 404, message: "Il repository \(owner)/\(repoName) non esiste e la creazione automatica è disattivata")
            }
            note("Creo il repository \(settings.privateRepos ? "privato" : "pubblico") \(owner)/\(repoName)")
            let isOrg = owner.lowercased() != user.login.lowercased()
            repoInfo = try await api.createRepo(owner: owner, name: repoName, isOrg: isOrg, isPrivate: settings.privateRepos,
                                                description: "Creato da ActionsRunner iOS per eseguire i workflow di \(proj.name)")
            // attesa che il repo sia pronto (auto_init crea il primo commit)
            for _ in 0..<15 {
                if try await api.ref(owner, repoName, branch: repoInfo?.defaultBranch ?? "main") != nil { break }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        guard let info = repoInfo else { throw GitHubError(status: 0, message: "Repository non disponibile") }
        let defaultBranch = info.defaultBranch ?? "main"

        // repo vuoto: inizializza con la Contents API (la Git Data API restituisce 409 su repo vuoti)
        if try await api.ref(owner, repoName, branch: defaultBranch) == nil {
            note("Repository vuoto: inizializzazione")
            try await api.send("PUT", "repos/\(owner)/\(repoName)/contents/.actionsrunner",
                               body: ["message": "Inizializzazione ActionsRunner", "content": Data("init\n".utf8).base64EncodedString(), "branch": defaultBranch])
        }

        proj.githubOwner = owner
        proj.githubRepo = repoName
        let branch = (branchOverride?.isEmpty == false ? branchOverride! : (proj.githubBranch ?? defaultBranch))
        proj.githubBranch = branch
        let projCopy = proj
        onMain { store.update(projCopy) }

        // secrets e variabili
        if settings.syncSecrets && (!settings.localSecrets.isEmpty || !settings.localVariables.isEmpty) {
            set(.syncingSecrets)
            if !settings.localSecrets.isEmpty {
                let key = try await api.publicKey(owner, repoName)
                for (k, v) in settings.localSecrets.sorted(by: { $0.key < $1.key }) {
                    note("Secret \(k)")
                    try await api.setSecret(owner, repoName, name: k, value: v, key: key)
                }
            }
            for (k, v) in settings.localVariables.sorted(by: { $0.key < $1.key }) {
                note("Variabile \(k)")
                try await api.setVariable(owner, repoName, name: k, value: v)
            }
        }

        // push
        set(.uploading)
        let pusher = RepoPusher(api: api, owner: owner, repo: repoName) { [weak self] p, m in
            onMain { self?.progress = p; self?.message = m }
        }
        let message = "ActionsRunner: \(proj.name) — \(ISODate.formatter.string(from: Date()))"
        let result = try await pusher.push(from: proj.repoURL, branch: branch, message: message, defaultBranch: defaultBranch)
        onMain { self.commitSHA = result.commitSHA }
        note("Commit \(result.commitSHA.prefix(7)) su \(result.branch) (\(result.fileCount) file)")
        proj.lastPushedSHA = result.commitSHA

        // trigger
        set(.triggering)
        let hasPush = workflow.triggers["push"] != nil &&
            FilterPattern.triggerMatches(config: workflow.triggers["push"], branch: result.branch, isTag: false)
        var runId: Int? = nil
        let useDispatch = trigger == .dispatch || (trigger == .automatic && !hasPush)
        if useDispatch {
            guard workflow.supportsDispatch else {
                throw GitHubError(status: 0, message: "Il workflow non dichiara 'workflow_dispatch' e il push su '\(result.branch)' non lo attiva. Aggiungi 'workflow_dispatch:' a 'on:' oppure usa un branch che corrisponde ai filtri push.")
            }
            note("workflow_dispatch di \(workflow.fileName) su \(result.branch)")
            var lastError: Error? = nil
            for attempt in 0..<12 {
                do {
                    let r = try await api.dispatch(owner, repoName, workflow: workflow.fileName, ref: result.branch, inputs: inputs)
                    runId = r?.workflowRunId
                    lastError = nil
                    break
                } catch let e as GitHubError where e.status == 404 || e.status == 422 {
                    // GitHub registra i workflow appena caricati con qualche secondo di ritardo
                    lastError = e
                    note("Workflow non ancora registrato da GitHub, nuovo tentativo (\(attempt + 1)/12)…")
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
            if let e = lastError { throw e }
        } else {
            note("Il push su \(result.branch) attiva il workflow (on: push)")
        }

        // ricerca della run
        set(.waitingForRun)
        if runId == nil {
            for _ in 0..<40 {
                try Task.checkCancellation()
                let runs = try await api.runs(owner, repoName, headSHA: result.commitSHA)
                let matching = runs.filter { ($0.path ?? "").hasPrefix(workflow.path) }
                let candidates = matching.isEmpty ? runs : matching
                if let r = candidates.sorted(by: { $0.id > $1.id }).first(where: { !useDispatch || $0.event == "workflow_dispatch" }) ?? candidates.first {
                    runId = r.id
                    break
                }
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        guard let id = runId else {
            throw GitHubError(status: 0, message: "Nessuna run trovata per il commit \(result.commitSHA.prefix(7)). Controlla che Actions sia abilitato nel repository e che i filtri 'on:' corrispondano.")
        }
        let run = try await api.workflowRun(owner, repoName, id: id)
        onMain { self.run = run }
        let record = CloudRunRecord(runId: id, owner: owner, repo: repoName, workflow: workflow.path, htmlUrl: run.htmlUrl, date: Date(), conclusion: nil)
        proj.cloudRuns.insert(record, at: 0)
        let finalProj = proj
        onMain { store.update(finalProj) }
        try await monitor(api: api, runId: id) { conclusion in
            var p = finalProj
            if let i = p.cloudRuns.firstIndex(where: { $0.runId == id }) { p.cloudRuns[i].conclusion = conclusion }
            onMain { store.update(p) }
        }
    }

    private func monitor(api: GitHubAPI, runId: Int, onFinish: ((String?) -> Void)?) async throws {
        set(.running)
        var fetchedLogs = Set<Int>()
        while true {
            try Task.checkCancellation()
            let run = try await api.workflowRun(owner, repo, id: runId)
            let jobs = (try? await api.jobs(owner, repo, runId: runId)) ?? []
            onMain { self.run = run; self.jobs = jobs }
            for j in jobs where j.status == "completed" && !fetchedLogs.contains(j.id) {
                fetchedLogs.insert(j.id)
                if let log = try? await api.jobLog(owner, repo, jobId: j.id) { onMain { self.logs[j.id] = log } }
                if let anns = try? await api.annotations(owner, repo, checkRunId: j.id), !anns.isEmpty {
                    onMain { self.annotations[j.id] = anns }
                }
            }
            if run.status == "completed" {
                let arts = (try? await api.artifacts(owner, repo, runId: runId)) ?? []
                onMain {
                    self.artifacts = arts
                    self.phase = .completed
                    self.progress = 1
                }
                note("Run completata: \(run.conclusion ?? "-")")
                onFinish?(run.conclusion)
                return
            }
            try await Task.sleep(nanoseconds: 4_000_000_000)
        }
    }

    func downloadArtifact(_ a: GHArtifact) {
        guard let api = api, !downloading.contains(a.id) else { return }
        downloading.insert(a.id)
        let owner = self.owner, repo = self.repo
        Task { [weak self] in
            let dest = AppPaths.cloudArtifacts.appendingPathComponent("\(repo)/\(self?.run?.id ?? 0)/\(a.name).zip")
            do {
                try await api.download(a.archiveDownloadUrl, to: dest)
                // se l'artifact contiene un solo .ipa lo estraiamo per poterlo condividere direttamente
                var final = dest
                let extractDir = dest.deletingPathExtension()
                if (try? ZipUtil.unzip(dest, to: extractDir)) != nil {
                    let ipas = ZipUtil.listFiles(in: extractDir).filter { $0.url.pathExtension.lowercased() == "ipa" }
                    if ipas.count == 1 { final = ipas[0].url }
                }
                onMain {
                    self?.downloaded[a.id] = final
                    self?.downloading.remove(a.id)
                }
                _ = owner
            } catch {
                onMain {
                    self?.downloading.remove(a.id)
                    self?.message = "Download fallito: \(error.localizedDescription)"
                }
            }
        }
    }

    func cancelRun() {
        guard let api = api, let run = run else { return }
        let owner = self.owner, repo = self.repo
        Task { try? await api.cancelRun(owner, repo, runId: run.id) }
    }

    func rerun(failedOnly: Bool, token: String) {
        guard let run = run else { return }
        let owner = self.owner, repo = self.repo
        let api = self.api ?? GitHubAPI(token: token)
        Task { [weak self] in
            do {
                try await api.rerun(owner, repo, runId: run.id, failedOnly: failedOnly)
                try await Task.sleep(nanoseconds: 2_000_000_000)
                self?.attach(owner: owner, repo: repo, runId: run.id, token: token)
            } catch {
                onMain { self?.message = error.localizedDescription }
            }
        }
    }
}
