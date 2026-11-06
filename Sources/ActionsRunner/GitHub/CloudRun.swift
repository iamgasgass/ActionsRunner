import Foundation
import Observation
import UIKit
import UserNotifications

/// Come avviare il workflow su GitHub.
enum CloudTrigger: String, CaseIterable, Identifiable, Codable {
    case auto, dispatch, push
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Automatico"
        case .dispatch: return "workflow_dispatch"
        case .push: return "push (commit)"
        }
    }
}

/// Richiesta di esecuzione su GitHub.
struct CloudRunRequest {
    var projectId: UUID?
    var projectURL: URL
    var repo: String
    var branch: String
    var workflowPath: String
    var workflowFile: String
    var title: String
    var trigger: CloudTrigger
    var inputs: [String: String]
    var commitMessage: String
    var syncSecrets: Bool
    var secrets: [String: String]
    var variables: [String: String]
}

/// Esecuzione salvata (per ritrovarla dopo il riavvio dell'app).
struct CloudRunRecord: Codable {
    var id: UUID
    var repo: String
    var workflowPath: String
    var branch: String
    var title: String
    var projectId: UUID?
    var createdAt: Date
    var commitSha: String?
    var runId: Int?
    var failure: String?
    var setupLog: [String]?

    private static var url: URL { AppPaths.support.appendingPathComponent("github-runs.json") }

    static func loadAll() -> [CloudRunRecord] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([CloudRunRecord].self, from: d)) ?? []
    }

    static func saveAll(_ records: [CloudRunRecord]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(Array(records.prefix(200))) { try? d.write(to: url, options: .atomic) }
    }
}

// MARK: - Modelli osservabili

@Observable
final class CloudJobModel: Identifiable {
    enum LogState: Equatable { case none, loading, partial, complete, unavailable(String) }

    let id: Int
    var job: GHJob
    var stepLogs: [Int: [LogLine]] = [:]
    var fullLog: [LogLine] = []
    var annotations: [GHAnnotation] = []
    var logState: LogState = .none
    @ObservationIgnored var lastLogAttempt: Date?
    @ObservationIgnored var annotationsLoaded = false

    init(job: GHJob) {
        id = job.id
        self.job = job
    }
}

@Observable
final class CloudRunModel: Identifiable {
    enum Phase: Equatable {
        case preparing, uploading, triggering, waitingForRun, running, finished, failed(String)
        var label: String {
            switch self {
            case .preparing: return "Preparazione"
            case .uploading: return "Caricamento su GitHub"
            case .triggering: return "Avvio del workflow"
            case .waitingForRun: return "In attesa della run"
            case .running: return "In esecuzione su GitHub"
            case .finished: return "Terminata"
            case .failed(let m): return "Errore: \(m)"
            }
        }
    }

    let id: UUID
    let repo: String
    let workflowPath: String
    var branch: String
    var title: String
    var projectId: UUID?
    let createdAt: Date
    var phase: Phase = .preparing
    var uploadProgress: Double?
    var setupLog: [String] = []
    var commitSha: String?
    var runId: Int?
    var run: GHRun?
    var jobs: [CloudJobModel] = []
    var artifacts: [GHArtifact] = []
    var artifactFiles: [Int: URL] = [:]
    var downloading: Set<Int> = []
    var transientError: String?
    var cancelRequested = false

    init(id: UUID = UUID(), repo: String, workflowPath: String, branch: String, title: String, projectId: UUID?, createdAt: Date = Date()) {
        self.id = id
        self.repo = repo
        self.workflowPath = workflowPath
        self.branch = branch
        self.title = title
        self.projectId = projectId
        self.createdAt = createdAt
    }

    var record: CloudRunRecord {
        var failure: String?
        if case .failed(let m) = phase { failure = m }
        return CloudRunRecord(id: id, repo: repo, workflowPath: workflowPath, branch: branch, title: title, projectId: projectId,
                              createdAt: createdAt, commitSha: commitSha, runId: runId, failure: failure,
                              setupLog: Array(setupLog.suffix(200)))
    }

    /// Stato e conclusione nel formato delle icone.
    var status: RunStatus {
        switch phase {
        case .failed, .finished: return .completed
        case .running:
            switch run?.status {
            case "completed": return .completed
            case "in_progress": return .inProgress
            case "queued", "waiting", "pending", "requested": return .queued
            default: return .queued
            }
        default: return .inProgress
        }
    }

    var conclusion: Conclusion? {
        if case .failed = phase { return .failure }
        return Conclusion(api: run?.conclusion)
    }

    var webURL: URL? { run.flatMap { URL(string: $0.htmlUrl) } }

    func log(_ s: String) { setupLog.append(s) }
}

// MARK: - Motore

/// Esegue e segue una run su GitHub. Tutto lo stato del modello è modificato sul main actor;
/// la rete e l'elaborazione dei log avvengono fuori dal main thread.
@MainActor
final class CloudRunEngine {
    let model: CloudRunModel
    private let api: GitHubAPI
    private let actions: GitHubActions
    private var task: Task<Void, Never>?
    private var background: UIBackgroundTaskIdentifier = .invalid
    var onChange: (() -> Void)?

    init(model: CloudRunModel, api: GitHubAPI) {
        self.model = model
        self.api = api
        actions = GitHubActions(api: api, repo: model.repo)
    }

    var isActive: Bool { task != nil }

    func start(_ request: CloudRunRequest) {
        task?.cancel()
        task = Task { [weak self] in
            await self?.execute(request)
            self?.task = nil
        }
    }

    /// Riprende il monitoraggio (dopo il riavvio dell'app o una nuova esecuzione).
    func resume() {
        guard model.runId != nil, task == nil else { return }
        if case .failed = model.phase { return }
        model.phase = .running
        task = Task { [weak self] in
            await self?.monitor()
            self?.task = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        endBackground()
    }

    private func beginBackground() {
        guard background == .invalid else { return }
        background = UIApplication.shared.beginBackgroundTask(withName: "github-run") { [weak self] in
            Task { @MainActor in self?.endBackground() }
        }
    }

    private func endBackground() {
        if background != .invalid {
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
    }

    private func fail(_ message: String) {
        model.phase = .failed(message)
        model.uploadProgress = nil
        onChange?()
    }

    // MARK: Avvio completo

    private func execute(_ r: CloudRunRequest) async {
        beginBackground()
        defer { endBackground() }
        CloudNotifications.requestAuthorizationIfNeeded()
        let model = self.model
        let log: (String) -> Void = { m in onMain { model.log(m) } }
        do {
            let repoInfo = try await actions.repository()
            if repoInfo.permissions?.push == false {
                throw GitHubError(status: 403, message: "il tuo account non ha accesso in scrittura a \(r.repo)")
            }
            log("Repository: \(repoInfo.fullName) (\(repoInfo.private ? "privato" : "pubblico")), branch \(r.branch)")

            let mode: CloudTrigger
            if r.trigger == .auto {
                let wf = WorkflowParser.loadWorkflows(in: r.projectURL).workflows.first { $0.path == r.workflowPath }
                mode = (wf?.supportsDispatch ?? false) ? .dispatch : .push
                log("Avvio: \(mode == .dispatch ? "workflow_dispatch (dichiarato dal workflow)" : "push (il workflow non dichiara workflow_dispatch)")")
            } else {
                mode = r.trigger
            }

            if r.syncSecrets && (!r.secrets.isEmpty || !r.variables.isEmpty) {
                model.phase = .preparing
                try await actions.syncSecretsAndVariables(secrets: r.secrets, variables: r.variables, log: log)
            }

            // 1. contenuto del progetto -> branch
            model.phase = .uploading
            model.uploadProgress = 0
            let uploader = RepoUploader(api: api, repo: r.repo)
            let pushed = try await uploader.push(directory: r.projectURL, branch: r.branch, message: r.commitMessage,
                                                 forceCommit: mode == .push, log: log,
                                                 progress: { p in onMain { model.uploadProgress = p } })
            model.uploadProgress = nil
            model.commitSha = pushed.commitSha
            log("Caricamento completato: \(pushed.uploadedBlobs) file inviati su \(pushed.totalFiles)")
            if Task.isCancelled { throw CancellationError() }

            // 2. avvio
            model.phase = .triggering
            let started = Date()
            var runId: Int?
            if mode == .dispatch {
                log("Invio di workflow_dispatch su \(r.branch)…")
                runId = try await actions.dispatch(workflowFile: r.workflowFile, ref: r.branch, inputs: r.inputs, log: log)
                if let runId { log("Run creata: #\(runId)") }
            }
            if runId == nil {
                model.phase = .waitingForRun
                log("Ricerca della run avviata da \(mode == .dispatch ? "workflow_dispatch" : "push") (\(pushed.commitSha.prefix(7)))…")
                let found = try await actions.findRun(workflowPath: r.workflowPath, headSha: pushed.commitSha,
                                                      event: mode == .dispatch ? "workflow_dispatch" : "push",
                                                      branch: r.branch, notBefore: started, timeout: 150,
                                                      isCancelled: { Task.isCancelled })
                guard let found else {
                    throw GitHubError(status: 0, message: mode == .push
                        ? "GitHub non ha avviato il workflow per questo push: controlla i filtri di on.push (branches, paths) e che GitHub Actions sia abilitato nel repository."
                        : "la run non è comparsa entro 150 secondi: controlla la pagina Actions del repository.")
                }
                runId = found.id
                model.run = found
            }
            model.runId = runId
            model.phase = .running
            onChange?()
            endBackground()
            await monitor()
        } catch is CancellationError {
            fail("annullata")
        } catch {
            log("Errore: \(error.localizedDescription)")
            fail(error.localizedDescription)
        }
    }

    // MARK: Monitoraggio

    private func monitor() async {
        guard let runId = model.runId else { return }
        var lastArtifacts = Date.distantPast
        var failures = 0
        while !Task.isCancelled {
            do {
                let run = try await actions.run(runId)
                model.run = run
                let jobs = try await actions.jobs(runId: runId)
                merge(jobs)
                try await refreshLogs(final: run.isCompleted)
                if run.isCompleted || Date().timeIntervalSince(lastArtifacts) > 30 {
                    model.artifacts = try await actions.artifacts(runId: runId)
                    lastArtifacts = Date()
                }
                model.transientError = nil
                failures = 0
                if run.isCompleted {
                    model.phase = .finished
                    model.cancelRequested = false
                    onChange?()
                    CloudNotifications.notifyFinished(model)
                    return
                }
            } catch is CancellationError {
                return
            } catch let e as GitHubError where e.status == 401 || e.status == 404 {
                fail(e.localizedDescription)
                return
            } catch {
                failures += 1
                model.transientError = "\(error.localizedDescription) — nuovo tentativo…"
            }
            let interval: Double
            if let rem = api.rateRemaining, rem < 300 {
                interval = 20
            } else if failures > 0 {
                interval = min(60, 3 * pow(2, Double(failures)))
            } else {
                interval = model.run?.status == "in_progress" ? 3 : 5
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    private func merge(_ jobs: [GHJob]) {
        var byId: [Int: CloudJobModel] = [:]
        for j in model.jobs { byId[j.id] = j }
        model.jobs = jobs.map { j in
            if let existing = byId[j.id] {
                if existing.job != j { existing.job = j }
                return existing
            }
            return CloudJobModel(job: j)
        }
    }

    /// Log e annotazioni: completi per i job terminati, parziali (ogni 15 s) per quelli in corso.
    private func refreshLogs(final: Bool) async throws {
        var fetched = 0
        for jm in model.jobs {
            if Task.isCancelled { return }
            let completed = jm.job.isCompleted
            if completed && jm.logState == .complete { continue }
            if case .unavailable = jm.logState, completed { continue }
            if !completed {
                guard jm.job.status == "in_progress" else { continue }
                if let last = jm.lastLogAttempt, Date().timeIntervalSince(last) < 15 { continue }
            }
            if fetched >= (final ? 50 : 3) { break }
            fetched += 1
            jm.lastLogAttempt = Date()
            if jm.logState == .none { jm.logState = .loading }
            await loadLog(jm, partial: !completed)
            if completed && !jm.annotationsLoaded {
                if let a = try? await actions.annotations(jobId: jm.id) { jm.annotations = a }
                jm.annotationsLoaded = true
            }
        }
    }

    private func loadLog(_ jm: CloudJobModel, partial: Bool) async {
        do {
            let text = try await actions.jobLog(jobId: jm.id)
            let steps = jm.job.steps ?? []
            let (lines, split) = await Task.detached(priority: .utility) { () -> ([LogLine], [Int: [LogLine]]) in
                let parsed = GitHubJobLog.parse(text)
                return (parsed.map(\.line), GitHubJobLog.split(parsed, steps: steps))
            }.value
            jm.fullLog = lines
            jm.stepLogs = split
            jm.logState = partial ? .partial : .complete
        } catch let e as GitHubError where e.status == 404 || e.status == 410 {
            if partial {
                if jm.logState == .loading { jm.logState = .none }
            } else {
                jm.logState = .unavailable(e.status == 410 ? "log scaduti" : "log non disponibili")
            }
        } catch {
            if !partial { jm.logState = .unavailable(error.localizedDescription) }
            else if jm.logState == .loading { jm.logState = .none }
        }
    }

    // MARK: Azioni

    func cancelRun(force: Bool) async throws {
        guard let id = model.runId else { return }
        try await actions.cancel(runId: id, force: force)
        model.cancelRequested = true
    }

    func rerun(failedOnly: Bool, debug: Bool) async throws {
        guard let id = model.runId else { return }
        try await actions.rerun(runId: id, failedOnly: failedOnly, debug: debug)
        task?.cancel()
        task = nil
        for j in model.jobs { j.logState = .none; j.annotationsLoaded = false }
        model.artifacts = []
        model.phase = .running
        model.log("Nuovo tentativo richiesto\(failedOnly ? " (solo job falliti)" : "")\(debug ? " con log di debug" : "")")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        resume()
    }

    func download(_ artifact: GHArtifact) async throws -> URL {
        if let u = model.artifactFiles[artifact.id], FileManager.default.fileExists(atPath: u.path) { return u }
        model.downloading.insert(artifact.id)
        defer { model.downloading.remove(artifact.id) }
        let tmp = try await actions.downloadArtifact(artifact)
        let dir = AppPaths.cloudArtifacts.appendingPathComponent("\(model.runId ?? 0)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(artifact.name).zip")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        model.artifactFiles[artifact.id] = dest
        return dest
    }
}

// MARK: - Notifiche

enum CloudNotifications {
    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            if s.authorizationStatus == .notDetermined {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        }
    }

    @MainActor
    static func notifyFinished(_ m: CloudRunModel) {
        guard UIApplication.shared.applicationState != .active else { return }
        let c = UNMutableNotificationContent()
        c.title = m.title
        c.body = "Run su GitHub: \(m.conclusion?.label ?? "terminata") · \(m.repo)"
        c.sound = .default
        let req = UNNotificationRequest(identifier: "run-\(m.id.uuidString)", content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
