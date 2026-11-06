import Foundation
import CryptoKit

struct LocalRunOptions {
    enum UnsupportedPolicy: String, CaseIterable, Identifiable {
        case fail, skip
        var id: String { rawValue }
        var label: String { self == .fail ? "Fallisci lo step (fedele)" : "Salta con avviso" }
    }

    var sourceURL: URL
    var eventName = "push"
    var ref = "refs/heads/main"
    var inputs: [String: String] = [:]
    var secrets: [String: String] = [:]
    var variables: [String: String] = [:]
    var repositoryOwner = "local"
    var repositoryName = "repo"
    var actor = "ios-user"
    var debug = false
    var onlyJob: String?
    var unsupportedActions: UnsupportedPolicy = .fail
    var runNumber = 1
    var shellEngine: ShellEngine = .auto
    var vmMemoryMB = 512
}

/// Dove eseguire gli step `run:`.
enum ShellEngine: String, CaseIterable, Identifiable {
    case auto, linux, builtin
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Automatico (VM Linux se disponibile)"
        case .linux: return "Solo VM Linux"
        case .builtin: return "Interprete integrato"
        }
    }
}

/// Ambito di valutazione degli step (job principale o azione composita).
final class StepScope {
    var steps = OrderedObject()
    var inputs: JSONValue?
    var actionPath: String?
    var actionRepository: String?
    var actionRef: String?
    var failed = false
    let isComposite: Bool
    init(isComposite: Bool) { self.isComposite = isComposite }
}

/// Stato di esecuzione di una singola istanza di job (una combinazione di matrix).
final class JobExecution {
    let job: Job
    let model: JobRunModel
    let root: URL
    let workspace: URL
    let temp: URL
    let home: URL
    let toolCache: URL
    var runnerOS = "Linux"
    var runnerArch = "X64"
    var github: OrderedObject
    var env = OrderedObject()              // env di workflow + job (valutati)
    var fileEnv = OrderedObject()          // variabili da $GITHUB_ENV
    var pathPrepend: [String] = []
    var contexts: [String: JSONValue] = [:]
    var failed = false
    let commands = CommandState()
    var postSteps: [(name: String, condition: String, run: (StepRunModel) async -> Bool)] = []
    var actionState: [String: OrderedObject] = [:]   // stato save-state per azione
    var summary = ""
    var defaultsRun: OrderedObject = OrderedObject()
    var deadline: Date

    init(job: Job, model: JobRunModel, root: URL, repoName: String, github: OrderedObject, timeoutMinutes: Double) {
        self.job = job
        self.model = model
        self.root = root
        workspace = root.appendingPathComponent("work/\(repoName)/\(repoName)", isDirectory: true)
        temp = root.appendingPathComponent("_temp", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        toolCache = root.appendingPathComponent("_tool", isDirectory: true)
        self.github = github
        deadline = Date().addingTimeInterval(timeoutMinutes * 60)
        let fm = FileManager.default
        for d in [workspace, temp, home, toolCache] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
    }
}

final class LocalWorkflowRunner {
    let workflow: Workflow
    let options: LocalRunOptions
    let model: LocalRunModel
    let runRoot: URL
    let artifactsDir: URL
    private(set) var cancelled = false
    private var interruptCurrentStep = false
    private var jobResults: [String: (result: String, outputs: OrderedObject)] = [:]
    private var sha: String
    private var runId: Int
    private lazy var fetcher = ActionFetcher()
    private var jobCounter = 0
    private var annotations: [RunAnnotation] = []

    init(workflow: Workflow, options: LocalRunOptions, model: LocalRunModel) {
        self.workflow = workflow
        self.options = options
        self.model = model
        let rid = Int.random(in: 10_000_000...99_999_999)
        let root = AppPaths.localRuns.appendingPathComponent("\(options.repositoryName)-\(rid)", isDirectory: true)
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        runId = rid
        runRoot = root
        artifactsDir = artifacts
        let digest = Insecure.SHA1.hash(data: Data("\(options.sourceURL.path)-\(Date().timeIntervalSince1970)".utf8))
        sha = digest.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
    }

    func cancel() {
        cancelled = true
        interruptCurrentStep = true
    }

    // MARK: - Workflow

    func run() async {
        let started = Date()
        let root = runRoot
        onMain {
            self.model.status = .inProgress
            self.model.startedAt = started
            self.model.rootURL = root
        }

        let github = buildGitHubContext()
        let inputs = buildInputs()

        // run-name
        if let rn = workflow.runName {
            var ctx = EvaluationContext()
            ctx["github"] = .object(github)
            ctx["inputs"] = inputs
            ctx["vars"] = .object(stringsObject(options.variables))
            if let title = try? ExpressionTemplate.evaluateString(rn, ctx) { onMain { self.model.title = title } }
        }

        let ordered: [Job]
        do { ordered = try JobGraph.topologicalOrder(workflow.jobs) } catch {
            finishRun(.failure, message: error.localizedDescription)
            return
        }

        // Crea i modelli dei job in anticipo (la UI mostra il grafo completo)
        var placeholders: [String: JobRunModel] = [:]
        let jobsToShow = ordered.filter { options.onlyJob == nil || $0.id == options.onlyJob }
        for j in jobsToShow {
            let m = JobRunModel(jobId: j.id, name: j.displayName)
            placeholders[j.id] = m
        }
        let initial = jobsToShow.compactMap { placeholders[$0.id] }
        onMain { self.model.jobs = initial }

        for job in ordered {
            if let only = options.onlyJob, job.id != only {
                jobResults[job.id] = (result: "success", outputs: OrderedObject())
                continue
            }
            let result = await runJob(job, github: github, inputs: inputs, placeholder: placeholders[job.id]!)
            jobResults[job.id] = result
        }

        let results = jobResults.values.map { $0.result }
        let conclusion: Conclusion = cancelled ? .cancelled : (results.contains("failure") ? .failure : .success)
        finishRun(conclusion, message: nil)
    }

    private func finishRun(_ conclusion: Conclusion, message: String?) {
        let artifacts = listArtifacts()
        let anns = annotations
        onMain {
            if let m = message { self.model.annotations.append(RunAnnotation(level: "error", message: m)) }
            self.model.annotations.append(contentsOf: anns.filter { a in !self.model.annotations.contains { $0.id == a.id } })
            self.model.artifacts = artifacts
            self.model.status = .completed
            self.model.conclusion = conclusion
            self.model.finishedAt = Date()
        }
    }

    private func listArtifacts() -> [LocalArtifact] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: artifactsDir, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        return files.filter { $0.pathExtension == "zip" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { u in
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
            return LocalArtifact(name: u.deletingPathExtension().lastPathComponent, url: u, size: Int64(size), fileCount: 0)
        }
    }

    private func stringsObject(_ d: [String: String]) -> OrderedObject {
        OrderedObject(d.keys.sorted().map { ($0, JSONValue.string(d[$0]!)) })
    }

    private func buildGitHubContext() -> OrderedObject {
        let owner = options.repositoryOwner
        let repoFull = "\(owner)/\(options.repositoryName)"
        let ref = options.ref
        let isTag = ref.hasPrefix("refs/tags/")
        let refName = ref.replacingOccurrences(of: "refs/heads/", with: "").replacingOccurrences(of: "refs/tags/", with: "")
        let repository: JSONValue = .object(OrderedObject([
            ("name", .string(options.repositoryName)), ("full_name", .string(repoFull)),
            ("owner", .object(OrderedObject([("login", .string(owner))]))),
            ("default_branch", .string("main")), ("private", .bool(true)),
            ("html_url", .string("https://github.com/\(repoFull)"))
        ]))
        let sender: JSONValue = .object(OrderedObject([("login", .string(options.actor)), ("type", .string("User"))]))
        var event = OrderedObject()
        switch options.eventName {
        case "workflow_dispatch":
            event["inputs"] = .object(stringsObject(options.inputs))
            event["ref"] = .string(ref)
            event["workflow"] = .string(workflow.path)
        case "pull_request", "pull_request_target":
            event["action"] = .string("opened")
            event["number"] = .number(1)
            event["pull_request"] = .object(OrderedObject([
                ("number", .number(1)), ("title", .string("Local pull request")), ("draft", .bool(false)),
                ("head", .object(OrderedObject([("ref", .string(refName)), ("sha", .string(sha))]))),
                ("base", .object(OrderedObject([("ref", .string("main")), ("sha", .string(String(repeating: "0", count: 40)))]))),
                ("labels", .array([])), ("user", sender)
            ]))
        case "release":
            event["action"] = .string("published")
            event["release"] = .object(OrderedObject([("tag_name", .string(refName)), ("name", .string(refName)), ("prerelease", .bool(false))]))
        default:
            event["ref"] = .string(ref)
            event["before"] = .string(String(repeating: "0", count: 40))
            event["after"] = .string(sha)
            event["created"] = .bool(false)
            event["deleted"] = .bool(false)
            event["forced"] = .bool(false)
            event["head_commit"] = .object(OrderedObject([
                ("id", .string(sha)), ("message", .string("Import da ActionsRunner iOS")),
                ("timestamp", .string(ISODate.formatter.string(from: Date()))),
                ("author", .object(OrderedObject([("name", .string(options.actor)), ("email", .string("\(options.actor)@users.noreply.github.com"))])))
            ]))
            event["pusher"] = .object(OrderedObject([("name", .string(options.actor))]))
        }
        event["repository"] = repository
        event["sender"] = sender

        var g = OrderedObject()
        g["action"] = .string("")
        g["action_path"] = .string("")
        g["action_ref"] = .string("")
        g["action_repository"] = .string("")
        g["actor"] = .string(options.actor)
        g["actor_id"] = .string("1")
        g["api_url"] = .string("https://api.github.com")
        g["base_ref"] = .string(options.eventName.hasPrefix("pull_request") ? "main" : "")
        g["event"] = .object(event)
        g["event_name"] = .string(options.eventName)
        g["event_path"] = .string(runRoot.appendingPathComponent("_github_workflow/event.json").path)
        g["graphql_url"] = .string("https://api.github.com/graphql")
        g["head_ref"] = .string(options.eventName.hasPrefix("pull_request") ? refName : "")
        g["job"] = .string("")
        g["path"] = .string("")
        g["ref"] = .string(options.eventName.hasPrefix("pull_request") ? "refs/pull/1/merge" : ref)
        g["ref_name"] = .string(options.eventName.hasPrefix("pull_request") ? "1/merge" : refName)
        g["ref_protected"] = .bool(false)
        g["ref_type"] = .string(isTag ? "tag" : "branch")
        g["repository"] = .string(repoFull)
        g["repository_id"] = .string("1")
        g["repository_owner"] = .string(owner)
        g["repository_owner_id"] = .string("1")
        g["repositoryUrl"] = .string("git://github.com/\(repoFull).git")
        g["retention_days"] = .string("90")
        g["run_attempt"] = .string("1")
        g["run_id"] = .string(String(runId))
        g["run_number"] = .string(String(options.runNumber))
        g["secret_source"] = .string("Actions")
        g["server_url"] = .string("https://github.com")
        g["sha"] = .string(sha)
        g["token"] = .string(options.secrets["GITHUB_TOKEN"] ?? "")
        g["triggering_actor"] = .string(options.actor)
        g["workflow"] = .string(workflow.name)
        g["workflow_ref"] = .string("\(repoFull)/\(workflow.path)@\(ref)")
        g["workflow_sha"] = .string(sha)
        g["workspace"] = .string("")

        let eventFile = runRoot.appendingPathComponent("_github_workflow/event.json")
        try? FileManager.default.createDirectory(at: eventFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONValue.object(event).toJSON().write(to: eventFile, atomically: true, encoding: .utf8)
        return g
    }

    /// Contesto `inputs` con i tipi dichiarati (boolean/number) e i default.
    private func buildInputs() -> JSONValue {
        var o = OrderedObject()
        let declared = options.eventName == "workflow_call" ? workflow.callInputs : workflow.dispatchInputs
        for input in declared {
            let raw = options.inputs[input.name]
            o[input.name] = typedInput(raw: raw, input: input)
        }
        for (k, v) in options.inputs where o[k] == nil { o[k] = .string(v) }
        return .object(o)
    }

    private func typedInput(raw: String?, input: WorkflowInput) -> JSONValue {
        let value: JSONValue
        if let r = raw { value = .string(r) } else { value = input.defaultValue ?? .null }
        switch input.type {
        case "boolean":
            switch value {
            case .bool: return value
            case .string(let s): return .bool(s.lowercased() == "true")
            case .null: return .bool(false)
            default: return .bool(value.isTruthy)
            }
        case "number":
            return .number(value.numberValue)
        default:
            if case .null = value { return .string("") }
            return .string(value.stringValue)
        }
    }

    // MARK: - Job

    private func runJob(_ job: Job, github: OrderedObject, inputs: JSONValue, placeholder: JobRunModel) async -> (result: String, outputs: OrderedObject) {
        // contesto needs
        var needsObj = OrderedObject()
        for n in job.needs {
            let r = jobResults[n] ?? (result: "skipped", outputs: OrderedObject())
            needsObj[n] = .object(OrderedObject([("result", .string(r.result)), ("outputs", .object(r.outputs))]))
        }
        let ancestors = JobGraph.ancestors(of: job.id, in: workflow.jobs)
        let ancestorResults = ancestors.compactMap { jobResults[$0]?.result }

        var ctx = EvaluationContext()
        ctx["github"] = .object(github)
        ctx["needs"] = .object(needsObj)
        ctx["vars"] = .object(stringsObject(options.variables))
        ctx["inputs"] = inputs
        ctx.status = StatusState(succeeded: ancestorResults.allSatisfy { $0 == "success" },
                                 failed: ancestorResults.contains("failure"),
                                 cancelled: cancelled)

        let shouldRun: Bool
        do { shouldRun = try ExpressionTemplate.evaluateCondition(job.ifCondition, ctx) } catch {
            appendJobLine(placeholder, "Errore nella condizione 'if' del job: \(error.localizedDescription)", .error)
            completeJob(placeholder, .failure)
            return ("failure", OrderedObject())
        }
        if !shouldRun {
            appendJobLine(placeholder, "Job saltato: la condizione 'if' è falsa\(job.ifCondition.map { " (\($0))" } ?? "") oppure un job richiesto non è riuscito.", .info)
            completeJob(placeholder, cancelled ? .cancelled : .skipped)
            return (cancelled ? "cancelled" : "skipped", OrderedObject())
        }

        if let uses = job.uses {
            return await runReusableWorkflow(job, uses: uses, github: github, inputs: inputs, needs: needsObj, model: placeholder)
        }

        // strategy / matrix
        var combos: [OrderedObject] = [OrderedObject()]
        var failFast = true
        var maxParallel: JSONValue = .null
        if let strategy = job.strategy {
            do {
                let evaluated = try ExpressionTemplate.evaluateDeep(strategy, ctx)
                if let matrix = evaluated["matrix"] {
                    var m = matrix
                    if case .string(let s) = matrix { m = try JSONValue.parse(json: s) }
                    combos = try MatrixExpander.expand(m)
                }
                if let ff = evaluated["fail-fast"] { failFast = ff.isTruthy }
                maxParallel = evaluated["max-parallel"] ?? .null
            } catch {
                appendJobLine(placeholder, "Errore nella strategy/matrix: \(error.localizedDescription)", .error)
                completeJob(placeholder, .failure)
                return ("failure", OrderedObject())
            }
        }

        // un modello per ogni combinazione
        var models: [JobRunModel] = []
        let nameIsCustom = job.name?.contains("${{") == true
        for (i, combo) in combos.enumerated() {
            var name = MatrixExpander.displayName(base: job.displayName, combo: combo, total: combos.count, nameIsCustom: nameIsCustom)
            if nameIsCustom, let raw = job.name {
                var c = ctx
                c["matrix"] = .object(combo)
                name = (try? ExpressionTemplate.evaluateString(raw, c)) ?? raw
            }
            let m = i == 0 ? placeholder : JobRunModel(jobId: job.id, name: name)
            let matrixValue: OrderedObject? = combo.isEmpty ? nil : combo
            if i == 0 {
                onMain { m.matrix = matrixValue; m.name = name }
            } else {
                m.matrix = matrixValue
            }
            models.append(m)
        }
        if models.count > 1 {
            let extra = Array(models.dropFirst())
            onMain {
                if let idx = self.model.jobs.firstIndex(where: { $0 === placeholder }) {
                    self.model.jobs.insert(contentsOf: extra, at: idx + 1)
                }
            }
        }

        var anyFailed = false
        var anyCancelled = false
        var outputs = OrderedObject()
        for (i, combo) in combos.enumerated() {
            if cancelled || (failFast && anyFailed) {
                appendJobLine(models[i], failFast && anyFailed ? "Annullato per fail-fast: un altro job della matrix è fallito." : "Annullato.", .info)
                completeJob(models[i], .cancelled)
                anyCancelled = true
                continue
            }
            let strategyCtx: JSONValue = .object(OrderedObject([
                ("fail-fast", .bool(failFast)), ("job-index", .number(Double(i))),
                ("job-total", .number(Double(combos.count))),
                ("max-parallel", maxParallel.isNull ? .number(Double(combos.count)) : maxParallel)
            ]))
            let (conclusion, out, continueOnError) = await runJobInstance(job, combo: combo, strategy: strategyCtx, github: github,
                                                                          inputs: inputs, needs: needsObj, model: models[i])
            outputs.merge(out)
            if conclusion == .failure && !continueOnError { anyFailed = true }
            if conclusion == .cancelled { anyCancelled = true }
        }
        let result = anyFailed ? "failure" : (anyCancelled || cancelled ? "cancelled" : "success")
        return (result, outputs)
    }

    private func appendJobLine(_ m: JobRunModel, _ text: String, _ kind: LogLine.Kind) {
        onMain {
            let step: StepRunModel
            if let s = m.steps.first, s.name == "Set up job" { step = s } else {
                step = StepRunModel(name: "Set up job")
                step.status = .completed
                step.conclusion = .success
                m.steps.insert(step, at: 0)
            }
            step.lines.append(LogLine(id: step.nextLineId, text: text, kind: kind, date: Date()))
            step.nextLineId += 1
        }
    }

    private func completeJob(_ m: JobRunModel, _ c: Conclusion) {
        onMain {
            m.status = .completed
            m.conclusion = c
            if m.startedAt == nil { m.startedAt = Date() }
            m.finishedAt = Date()
        }
    }

    // MARK: - Istanza di job

    private func runJobInstance(_ job: Job, combo: OrderedObject, strategy: JSONValue, github baseGithub: OrderedObject,
                                inputs: JSONValue, needs: OrderedObject, model jm: JobRunModel) async -> (Conclusion, OrderedObject, Bool) {
        jobCounter += 1
        let root = runRoot.appendingPathComponent("jobs/\(jobCounter)", isDirectory: true)
        var github = baseGithub
        github["job"] = .string(job.id)

        // contesto preliminare per runs-on / env / timeout
        var pre = EvaluationContext()
        pre["github"] = .object(github)
        pre["needs"] = .object(needs)
        pre["strategy"] = strategy
        pre["matrix"] = .object(combo)
        pre["vars"] = .object(stringsObject(options.variables))
        pre["secrets"] = .object(secretsObject())
        pre["inputs"] = inputs

        let timeout = (try? job.timeoutMinutes.map { try ExpressionTemplate.evaluateDeep($0, pre).numberValue }) ?? nil
        let exec = JobExecution(job: job, model: jm, root: root, repoName: options.repositoryName, github: github,
                                timeoutMinutes: (timeout ?? 360).isNaN ? 360 : (timeout ?? 360))
        exec.commands.debug = options.debug
        for (_, v) in options.secrets where !v.isEmpty { exec.commands.addMask(v) }
        exec.github["workspace"] = .string(exec.workspace.path)

        let setup = StepRunModel(name: "Set up job")
        setup.status = .inProgress
        setup.startedAt = Date()
        onMain {
            jm.status = .inProgress
            jm.startedAt = Date()
            if jm.steps.first?.name == "Set up job" { jm.steps.removeFirst() }
            jm.steps.insert(setup, at: 0)
        }
        func slog(_ s: String, _ k: LogLine.Kind = .output) { emit(setup, s, k) }

        // runs-on
        var label = "ubuntu-latest"
        if let ro = job.runsOn {
            do {
                let v = try ExpressionTemplate.evaluateDeep(ro, pre)
                switch v {
                case .array(let a): label = a.map { $0.stringValue }.joined(separator: ", ")
                case .object(let o): label = o["labels"].map { $0.arrayValue?.map { $0.stringValue }.joined(separator: ", ") ?? $0.stringValue } ?? (o["group"]?.stringValue ?? "self-hosted")
                default: label = v.stringValue
                }
            } catch { slog("Errore in runs-on: \(error.localizedDescription)", .error) }
        }
        let lower = label.lowercased()
        if lower.contains("macos") || lower.contains("mac") { exec.runnerOS = "macOS"; exec.runnerArch = lower.contains("intel") || lower.contains("13") ? "X64" : "ARM64" }
        else if lower.contains("windows") { exec.runnerOS = "Windows"; exec.runnerArch = "X64" }
        else { exec.runnerOS = "Linux"; exec.runnerArch = lower.contains("arm") ? "ARM64" : "X64" }
        onMain { jm.runsOn = label }

        slog("Current runner version: '2.329.0' (ActionsRunner per iOS)")
        slog("Runner name: 'ActionsRunner iOS'")
        slog("Machine name: '\(UIDeviceInfo.name)'")
        slog("Etichetta richiesta (runs-on): \(label)", .info)
        emit(setup, "Runner Image", .groupStart)
        if options.shellEngine != .builtin && LinuxVM.shared.isSupported {
            slog("Image: VM Linux integrata (TinyEMU RISC-V 64 + Alpine Linux) — runner.os: \(exec.runnerOS)")
            if exec.runnerOS != "Linux" {
                slog("runs-on '\(label)' richiede \(exec.runnerOS): gli step verranno eseguiti nella VM Linux; gli strumenti specifici di \(exec.runnerOS) (es. xcodebuild) non esistono.", .warning)
            }
        } else {
            slog("Image: interprete bash integrato (Swift) — runner.os: \(exec.runnerOS)")
        }
        emit(setup, "", .groupEnd)
        if let perms = job.permissions ?? workflow.permissions {
            emit(setup, "GITHUB_TOKEN Permissions", .groupStart)
            if let o = perms.objectValue { for (k, v) in o.pairs { slog("\(k): \(v.stringValue)") } } else { slog(perms.stringValue) }
            emit(setup, "", .groupEnd)
        }
        slog("Secret source: Actions")
        slog("Prepare workflow directory")
        if job.container != nil { slog("'container' richiede Docker, che non può girare nell'app: gli step vengono eseguiti senza container.", .warning) }
        if job.services != nil { slog("'services' richiede Docker: i container di servizio non verranno avviati.", .warning) }
        if let envName = job.environment {
            slog("Environment: \((try? ExpressionTemplate.evaluateDeep(envName, pre).stringValue) ?? envName.stringValue) (le regole di protezione non sono emulate)", .info)
        }

        // env di workflow e di job
        do {
            if let wenv = workflow.env?.objectValue {
                var c = pre
                c["env"] = .object(OrderedObject())
                for (k, v) in wenv.pairs {
                    c["env"] = .object(exec.env)
                    exec.env[k] = .string(try ExpressionTemplate.evaluateDeep(v, c).stringValue)
                }
            }
            if let jenv = job.env {
                var c = pre
                c["env"] = .object(exec.env)
                let evaluated = try ExpressionTemplate.evaluateDeep(jenv, c)
                if let o = evaluated.objectValue { for (k, v) in o.pairs { exec.env[k] = .string(v.stringValue) } }
            }
        } catch {
            slog("Errore nella valutazione di env: \(error.localizedDescription)", .error)
            finishSetup(setup, .failure)
            completeJob(jm, .failure)
            return (.failure, OrderedObject(), false)
        }

        // defaults.run (job prevale su workflow)
        var defaults = OrderedObject()
        if let w = workflow.defaults?["run"]?.objectValue { defaults.merge(w) }
        if let j = job.defaults?["run"]?.objectValue { defaults.merge(j) }
        exec.defaultsRun = defaults

        // contesti
        exec.contexts["needs"] = .object(needs)
        exec.contexts["strategy"] = strategy
        exec.contexts["matrix"] = .object(combo)
        exec.contexts["inputs"] = inputs
        exec.contexts["vars"] = .object(stringsObject(options.variables))
        exec.contexts["secrets"] = .object(secretsObject())
        exec.contexts["runner"] = .object(OrderedObject([
            ("name", .string("ActionsRunner iOS")), ("os", .string(exec.runnerOS)), ("arch", .string(exec.runnerArch)),
            ("temp", .string(exec.temp.path)), ("tool_cache", .string(exec.toolCache.path)),
            ("workspace", .string(exec.workspace.deletingLastPathComponent().path)),
            ("environment", .string("github-hosted")), ("debug", .string(options.debug ? "1" : ""))
        ]))
        exec.contexts["job"] = .object(OrderedObject([
            ("status", .string("success")), ("check_run_id", .number(Double(runId + jobCounter))),
            ("container", .object(OrderedObject([("id", .string("")), ("network", .string(""))]))),
            ("services", .object(OrderedObject()))
        ]))

        // Pre-download delle azioni remote non emulate (come "Prepare all required actions")
        emit(setup, "Prepare all required actions", .groupStart)
        var seen = Set<String>()
        for step in job.steps {
            guard let uses = step.uses, let ref = try? ActionReference(uses) else { continue }
            guard case .remote(let o, let r, _, let rf) = ref.kind else { continue }
            if seen.contains(ref.key + rf) { continue }
            seen.insert(ref.key + rf)
            if BuiltinActions.isEmulated(ref.key) {
                slog("Azione '\(uses)': emulata nativamente")
                continue
            }
            do { _ = try await fetcher.fetch(owner: o, repo: r, ref: rf, log: { slog($0) }) }
            catch { slog("Impossibile scaricare '\(uses)': \(error.localizedDescription)", .warning) }
        }
        emit(setup, "", .groupEnd)
        slog("Complete job name: \(jm.name)")
        finishSetup(setup, .success)

        // Step
        let scope = StepScope(isComposite: false)
        scope.inputs = inputs
        await runSteps(job.steps, exec: exec, scope: scope, parentModel: nil)

        // Post-step in ordine inverso
        for post in exec.postSteps.reversed() {
            let pm = StepRunModel(name: post.name)
            pm.isPost = true
            onMain { jm.steps.append(pm) }
            var c = makeContext(exec, scope)
            c.status = StatusState(succeeded: !exec.failed, failed: exec.failed, cancelled: cancelled)
            let run = (try? ExpressionTemplate.evaluateCondition(post.condition, c)) ?? true
            if !run {
                finishStep(pm, conclusion: .skipped, outcome: .skipped)
                continue
            }
            startStep(pm)
            interruptCurrentStep = false
            let ok = await post.run(pm)
            finishStep(pm, conclusion: ok ? .success : .failure, outcome: ok ? .success : .failure)
            if !ok { exec.failed = true }
        }

        // Output del job
        var outputs = OrderedObject()
        let outCtx = makeContext(exec, scope)
        for (k, v) in job.outputs.pairs {
            if let s = try? ExpressionTemplate.evaluateString(v.stringValue, outCtx) {
                outputs[k] = .string(s)
            }
        }
        let continueOnError = (try? job.continueOnError.map { try ExpressionTemplate.evaluateDeep($0, makeContext(exec, scope)).isTruthy }) ?? false
        let conclusion: Conclusion = cancelled ? .cancelled : (exec.failed ? .failure : .success)
        let outDict = Dictionary(uniqueKeysWithValues: outputs.pairs.map { ($0.key, $0.value.stringValue) })
        let summary = exec.summary
        let complete = StepRunModel(name: "Complete job")
        complete.status = .completed
        complete.conclusion = .success
        complete.lines = [LogLine(id: 0, text: "Cleaning up orphan processes", kind: .output, date: Date())]
        onMain {
            jm.steps.append(complete)
            jm.outputs = outDict
            jm.summary = summary
        }
        completeJob(jm, conclusion)
        return (conclusion, outputs, continueOnError)
    }

    private func secretsObject() -> OrderedObject {
        var o = stringsObject(options.secrets)
        if o["GITHUB_TOKEN"] == nil { o["GITHUB_TOKEN"] = .string("") }
        return o
    }

    private func finishSetup(_ s: StepRunModel, _ c: Conclusion) {
        onMain {
            s.status = .completed
            s.conclusion = c
            s.outcome = c
            s.finishedAt = Date()
        }
    }

    // MARK: - Contesto di valutazione

    func makeContext(_ exec: JobExecution, _ scope: StepScope, extraEnv: OrderedObject? = nil) -> EvaluationContext {
        var ctx = EvaluationContext()
        var g = exec.github
        if let p = scope.actionPath { g["action_path"] = .string(p) }
        if let r = scope.actionRepository { g["action_repository"] = .string(r) }
        if let r = scope.actionRef { g["action_ref"] = .string(r) }
        ctx["github"] = .object(g)
        var env = exec.env.merging(exec.fileEnv)
        if let e = extraEnv { env.merge(e) }
        ctx["env"] = .object(env)
        for (k, v) in exec.contexts { ctx[k] = v }
        if let i = scope.inputs { ctx["inputs"] = i }
        ctx["steps"] = .object(scope.steps)
        var jobCtx = exec.contexts["job"]?.objectValue ?? OrderedObject()
        jobCtx["status"] = .string(cancelled ? "cancelled" : (exec.failed ? "failure" : "success"))
        ctx["job"] = .object(jobCtx)
        let failed = exec.failed || scope.failed
        ctx.status = StatusState(succeeded: !failed, failed: failed, cancelled: cancelled)
        let ws = exec.workspace
        ctx.hashFiles = { patterns in PathGlob.hashFiles(patterns, root: ws) }
        return ctx
    }

    // MARK: - Step

    private func runSteps(_ steps: [Step], exec: JobExecution, scope: StepScope, parentModel: StepRunModel?) async {
        for step in steps {
            await runStep(step, exec: exec, scope: scope, parentModel: parentModel)
        }
    }

    private func runStep(_ step: Step, exec: JobExecution, scope: StepScope, parentModel: StepRunModel?) async {
        let ctxForName = makeContext(exec, scope)
        let displayName: String = {
            if let n = step.name, let s = try? ExpressionTemplate.evaluateString(n, ctxForName) { return s }
            return step.defaultDisplayName
        }()

        // Negli step compositi il log finisce nello step padre
        let sm: StepRunModel
        if let parent = parentModel {
            sm = parent
            emit(sm, displayName, .groupStart)
        } else {
            sm = StepRunModel(name: displayName)
            onMain { exec.model.steps.append(sm) }
        }

        // if
        let condCtx = makeContext(exec, scope)
        let shouldRun: Bool
        do { shouldRun = try ExpressionTemplate.evaluateCondition(step.ifCondition, condCtx) } catch {
            emit(sm, "Errore nella condizione 'if': \(error.localizedDescription)", .error)
            markFailure(exec, scope)
            recordStep(step, scope, outcome: .failure, conclusion: .failure, outputs: OrderedObject())
            if parentModel == nil { finishStep(sm, conclusion: .failure, outcome: .failure) } else { emit(sm, "", .groupEnd) }
            return
        }
        if !shouldRun {
            recordStep(step, scope, outcome: .skipped, conclusion: .skipped, outputs: OrderedObject())
            if parentModel == nil { finishStep(sm, conclusion: .skipped, outcome: .skipped) } else { emit(sm, "Saltato (if: falso)", .info); emit(sm, "", .groupEnd) }
            return
        }

        if parentModel == nil { startStep(sm) }
        interruptCurrentStep = false

        // env dello step
        var stepEnv = OrderedObject()
        if let e = step.env {
            do {
                let evaluated = try ExpressionTemplate.evaluateDeep(e, makeContext(exec, scope))
                if let o = evaluated.objectValue { for (k, v) in o.pairs { stepEnv[k] = .string(v.stringValue) } }
            } catch {
                emit(sm, "Errore in env dello step: \(error.localizedDescription)", .error)
                markFailure(exec, scope)
                recordStep(step, scope, outcome: .failure, conclusion: .failure, outputs: OrderedObject())
                if parentModel == nil { finishStep(sm, conclusion: .failure, outcome: .failure) } else { emit(sm, "", .groupEnd) }
                return
            }
        }

        let ctx = makeContext(exec, scope, extraEnv: stepEnv)
        var stepTimeout: Date? = nil
        if let t = step.timeoutMinutes, let v = try? ExpressionTemplate.evaluateDeep(t, ctx).numberValue, !v.isNaN {
            stepTimeout = Date().addingTimeInterval(v * 60)
        }
        let deadline = min(stepTimeout ?? exec.deadline, exec.deadline)

        var success = false
        var outputs = OrderedObject()
        if let run = step.run {
            let script: String
            do { script = try ExpressionTemplate.evaluateString(run, ctx) } catch {
                emit(sm, "Errore nell'espressione: \(error.localizedDescription)", .error)
                script = ""
            }
            if !script.isEmpty || run.isEmpty {
                let (ok, outs) = await runScriptStep(script: script, step: step, exec: exec, scope: scope, stepEnv: stepEnv, model: sm, ctx: ctx, deadline: deadline)
                success = ok
                outputs = outs
            }
        } else if let uses = step.uses {
            let (ok, outs) = await runActionStep(uses: uses, step: step, exec: exec, scope: scope, stepEnv: stepEnv, model: sm, ctx: ctx, deadline: deadline)
            success = ok
            outputs = outs
        }

        if Date() > deadline && !success {
            emit(sm, "##[error]Lo step ha superato il timeout di \(step.timeoutMinutes?.stringValue ?? "job") minuti.", .error)
        }

        let outcome: Conclusion = interruptCurrentStep && cancelled ? .cancelled : (success ? .success : .failure)
        var conclusion = outcome
        if outcome == .failure {
            let coe = (try? step.continueOnError.map { try ExpressionTemplate.evaluateDeep($0, makeContext(exec, scope)).isTruthy }) ?? nil
            if coe == true {
                conclusion = .success
                emit(sm, "continue-on-error: lo step è fallito ma il job prosegue.", .warning)
            } else {
                markFailure(exec, scope)
            }
        }
        recordStep(step, scope, outcome: outcome, conclusion: conclusion, outputs: outputs)
        if parentModel == nil {
            finishStep(sm, conclusion: conclusion, outcome: outcome)
        } else {
            emit(sm, "", .groupEnd)
        }
    }

    private func markFailure(_ exec: JobExecution, _ scope: StepScope) {
        if scope.isComposite { scope.failed = true } else { exec.failed = true }
    }

    private func recordStep(_ step: Step, _ scope: StepScope, outcome: Conclusion, conclusion: Conclusion, outputs: OrderedObject) {
        guard let id = step.stepId else { return }
        scope.steps[id] = .object(OrderedObject([
            ("outputs", .object(outputs)), ("outcome", .string(outcome.rawValue)), ("conclusion", .string(conclusion.rawValue))
        ]))
    }

    private func startStep(_ sm: StepRunModel) {
        onMain {
            sm.status = .inProgress
            sm.startedAt = Date()
        }
    }

    private func finishStep(_ sm: StepRunModel, conclusion: Conclusion, outcome: Conclusion) {
        onMain {
            sm.status = .completed
            sm.conclusion = conclusion
            sm.outcome = outcome
            if sm.startedAt == nil { sm.startedAt = Date() }
            sm.finishedAt = Date()
        }
    }

    func emit(_ sm: StepRunModel, _ text: String, _ kind: LogLine.Kind) {
        let date = Date()
        onMain {
            if sm.lines.count > 60_000 { return }
            sm.lines.append(LogLine(id: sm.nextLineId, text: text, kind: kind, date: date))
            sm.nextLineId += 1
        }
    }

    func addAnnotation(_ a: RunAnnotation, job: JobExecution) {
        var ann = a
        ann.context = job.model.name
        annotations.append(ann)
        onMain { self.model.annotations.append(ann) }
    }

    /// Sink che separa l'output in righe, applica maschere e comandi di workflow.
    func makeSink(_ sm: StepRunModel, exec: JobExecution, scope: StepScope, outputs: @escaping (String, String) -> Void,
                  state: @escaping (String, String) -> Void) -> (CallbackSink, () -> Void) {
        var buffer = ""
        let process: (String) -> Void = { [weak self] line in
            guard let self = self else { return }
            switch WorkflowCommands.process(line, exec.commands) {
            case .log(let kind, let text): self.emit(sm, exec.commands.mask(text), kind)
            case .annotation(let a, let text):
                var masked = a
                masked = RunAnnotation(level: a.level, message: exec.commands.mask(a.message), title: a.title, file: a.file, line: a.line)
                self.addAnnotation(masked, job: exec)
                self.emit(sm, exec.commands.mask(text), a.level == "error" ? .error : (a.level == "warning" ? .warning : .notice))
            case .setOutput(let n, let v):
                self.emit(sm, "Warning: il comando `set-output` è deprecato. Usa i file di ambiente ($GITHUB_OUTPUT).", .warning)
                outputs(n, v)
            case .saveState(let n, let v): state(n, v)
            case .none: break
            }
        }
        let sink = CallbackSink { text in
            buffer += text
            while let nl = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<nl])
                buffer = String(buffer[buffer.index(after: nl)...])
                process(line)
            }
        }
        let flush: () -> Void = {
            if !buffer.isEmpty { process(buffer); buffer = "" }
        }
        return (sink, flush)
    }

    // MARK: - Ambiente

    /// Variabili d'ambiente come le vede il processo dello step.
    func processEnvironment(exec: JobExecution, scope: StepScope, stepEnv: OrderedObject, files: [String: URL], action: String) -> [String: String] {
        var env: [String: String] = [:]
        let g = exec.github
        func gs(_ k: String) -> String { g[k]?.stringValue ?? "" }
        env["CI"] = "true"
        env["GITHUB_ACTIONS"] = "true"
        env["HOME"] = exec.home.path
        env["USER"] = "runner"
        env["SHELL"] = "/bin/bash"
        env["LANG"] = "C.UTF-8"
        env["TERM"] = "dumb"
        env["IMAGE_OS"] = exec.runnerOS == "macOS" ? "macos26" : "ubuntu24"
        env["GITHUB_ACTION"] = action
        env["GITHUB_ACTION_PATH"] = scope.actionPath ?? ""
        env["GITHUB_ACTION_REPOSITORY"] = scope.actionRepository ?? ""
        env["GITHUB_ACTION_REF"] = scope.actionRef ?? ""
        env["GITHUB_ACTOR"] = gs("actor")
        env["GITHUB_ACTOR_ID"] = gs("actor_id")
        env["GITHUB_API_URL"] = gs("api_url")
        env["GITHUB_BASE_REF"] = gs("base_ref")
        env["GITHUB_EVENT_NAME"] = gs("event_name")
        env["GITHUB_EVENT_PATH"] = gs("event_path")
        env["GITHUB_GRAPHQL_URL"] = gs("graphql_url")
        env["GITHUB_HEAD_REF"] = gs("head_ref")
        env["GITHUB_JOB"] = gs("job")
        env["GITHUB_REF"] = gs("ref")
        env["GITHUB_REF_NAME"] = gs("ref_name")
        env["GITHUB_REF_PROTECTED"] = "false"
        env["GITHUB_REF_TYPE"] = gs("ref_type")
        env["GITHUB_REPOSITORY"] = gs("repository")
        env["GITHUB_REPOSITORY_ID"] = gs("repository_id")
        env["GITHUB_REPOSITORY_OWNER"] = gs("repository_owner")
        env["GITHUB_REPOSITORY_OWNER_ID"] = gs("repository_owner_id")
        env["GITHUB_RETENTION_DAYS"] = "90"
        env["GITHUB_RUN_ATTEMPT"] = gs("run_attempt")
        env["GITHUB_RUN_ID"] = gs("run_id")
        env["GITHUB_RUN_NUMBER"] = gs("run_number")
        env["GITHUB_SERVER_URL"] = gs("server_url")
        env["GITHUB_SHA"] = gs("sha")
        env["GITHUB_TRIGGERING_ACTOR"] = gs("triggering_actor")
        env["GITHUB_WORKFLOW"] = gs("workflow")
        env["GITHUB_WORKFLOW_REF"] = gs("workflow_ref")
        env["GITHUB_WORKFLOW_SHA"] = gs("workflow_sha")
        env["GITHUB_WORKSPACE"] = exec.workspace.path
        env["RUNNER_ARCH"] = exec.runnerArch
        env["RUNNER_NAME"] = "ActionsRunner iOS"
        env["RUNNER_OS"] = exec.runnerOS
        env["RUNNER_TEMP"] = exec.temp.path
        env["RUNNER_TOOL_CACHE"] = exec.toolCache.path
        env["RUNNER_WORKSPACE"] = exec.workspace.deletingLastPathComponent().path
        env["RUNNER_ENVIRONMENT"] = "github-hosted"
        if options.debug { env["RUNNER_DEBUG"] = "1"; env["ACTIONS_STEP_DEBUG"] = "true" }
        env["ImageOS"] = env["IMAGE_OS"]
        for (k, u) in files { env[k] = u.path }
        var path = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if !exec.pathPrepend.isEmpty { path = exec.pathPrepend.reversed().joined(separator: ":") + ":" + path }
        env["PATH"] = path
        for (k, v) in exec.env.pairs { env[k] = v.stringValue }
        for (k, v) in exec.fileEnv.pairs { env[k] = v.stringValue }
        for (k, v) in stepEnv.pairs { env[k] = v.stringValue }
        return env
    }

    /// Crea i file di comando ($GITHUB_OUTPUT ecc.) per uno step.
    func makeCommandFiles(_ exec: JobExecution) -> [String: URL] {
        let dir = exec.temp.appendingPathComponent("_runner_file_commands", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        var files: [String: URL] = [:]
        for (k, prefix) in [("GITHUB_OUTPUT", "set_output_"), ("GITHUB_ENV", "set_env_"), ("GITHUB_PATH", "add_path_"),
                            ("GITHUB_STEP_SUMMARY", "step_summary_"), ("GITHUB_STATE", "save_state_")] {
            let u = dir.appendingPathComponent(prefix + id)
            FileManager.default.createFile(atPath: u.path, contents: Data())
            files[k] = u
        }
        return files
    }

    /// Applica i file di comando al termine dello step.
    func applyCommandFiles(_ files: [String: URL], exec: JobExecution, model sm: StepRunModel, outputs: inout OrderedObject, state: inout OrderedObject) -> Bool {
        var ok = true
        func read(_ k: String) -> String { (files[k]).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "" }
        do {
            for (k, v) in try EnvironmentFile.parse(read("GITHUB_OUTPUT")) { outputs[k] = .string(v) }
        } catch { emit(sm, "##[error]GITHUB_OUTPUT: \(error.localizedDescription)", .error); ok = false }
        do {
            for (k, v) in try EnvironmentFile.parse(read("GITHUB_ENV")) {
                let upper = k.uppercased()
                if upper == "NODE_OPTIONS" || upper.hasPrefix("GITHUB_") && !["GITHUB_TOKEN"].contains(upper) || upper.hasPrefix("RUNNER_") {
                    emit(sm, "Warning: non è consentito impostare '\(k)' tramite GITHUB_ENV.", .warning)
                    continue
                }
                exec.fileEnv[k] = .string(v)
            }
        } catch { emit(sm, "##[error]GITHUB_ENV: \(error.localizedDescription)", .error); ok = false }
        for line in read("GITHUB_PATH").components(separatedBy: "\n") {
            let p = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty { exec.pathPrepend.append(p) }
        }
        let summary = read("GITHUB_STEP_SUMMARY")
        if !summary.isEmpty {
            if summary.utf8.count > 1_048_576 {
                emit(sm, "Warning: il riepilogo dello step supera 1 MiB e verrà ignorato.", .warning)
            } else {
                exec.summary += summary
                if !summary.hasSuffix("\n") { exec.summary += "\n" }
            }
        }
        do {
            for (k, v) in try EnvironmentFile.parse(read("GITHUB_STATE")) { state[k] = .string(v) }
        } catch { emit(sm, "##[error]GITHUB_STATE: \(error.localizedDescription)", .error) }
        return ok
    }

    // MARK: - run:

    private func runScriptStep(script: String, step: Step, exec: JobExecution, scope: StepScope, stepEnv: OrderedObject,
                               model sm: StepRunModel, ctx: EvaluationContext, deadline: Date) async -> (Bool, OrderedObject) {
        switch await prepareVM(sm) {
        case .vm:
            return await runScriptInVM(script: script, step: step, exec: exec, scope: scope, stepEnv: stepEnv, model: sm, ctx: ctx, deadline: deadline)
        case .fail:
            return (false, OrderedObject())
        case .builtin:
            break
        }
        // shell: step > defaults.run.shell (job/workflow) > default
        var shellSpec = step.shell ?? exec.defaultsRun["shell"]?.stringValue ?? ""
        if shellSpec.contains("${{") { shellSpec = (try? ExpressionTemplate.evaluateString(shellSpec, ctx)) ?? shellSpec }
        let explicit = !shellSpec.isEmpty
        var shellName = shellSpec.split(separator: " ").first.map(String.init) ?? ""
        if !explicit { shellName = exec.runnerOS == "Windows" ? "pwsh" : "bash" }

        var displayShell: String
        var errexit = true
        var pipefail = false
        switch shellName {
        case "bash", "/bin/bash", "/usr/bin/bash":
            if explicit && shellSpec.contains("{0}") {
                displayShell = "/usr/bin/" + shellSpec
                errexit = shellSpec.contains(" -e") || shellSpec.contains("-eo")
                pipefail = shellSpec.contains("pipefail")
            } else if explicit {
                displayShell = "/usr/bin/bash --noprofile --norc -eo pipefail {0}"
                pipefail = true
            } else {
                displayShell = "/usr/bin/bash -e {0}"
            }
        case "sh", "/bin/sh":
            displayShell = shellSpec.contains("{0}") ? "/bin/" + shellSpec : "/bin/sh -e {0}"
            errexit = !shellSpec.contains("{0}") || shellSpec.contains("-e")
        default:
            emit(sm, "Run \(script.split(separator: "\n").first ?? "")", .groupStart)
            emit(sm, script, .command)
            emit(sm, "", .groupEnd)
            emit(sm, "##[error]La shell '\(shellName)' non è disponibile nell'interprete integrato (supportate: bash, sh). Esegui lo step nella VM Linux (Impostazioni → Esecuzione degli step), che supporta anche python, node e shell personalizzate.", .error)
            return (false, OrderedObject())
        }

        // working-directory
        var wd = step.workingDirectory ?? exec.defaultsRun["working-directory"]?.stringValue
        if let w = wd, w.contains("${{") { wd = try? ExpressionTemplate.evaluateString(w, ctx) }
        var cwd = exec.workspace
        if let w = wd, !w.isEmpty {
            cwd = w.hasPrefix("/") ? URL(fileURLWithPath: w) : exec.workspace.appendingPathComponent(w)
        }
        guard FileCommands.isDir(cwd) else {
            emit(sm, "##[error]An error occurred trying to start process '/usr/bin/bash' with working directory '\(cwd.path)'. No such file or directory", .error)
            return (false, OrderedObject())
        }

        // Log in stile GitHub
        let lines = script.components(separatedBy: "\n")
        emit(sm, "Run \(lines.first ?? "")", .groupStart)
        for l in lines.dropLast(script.hasSuffix("\n") ? 1 : 0) { emit(sm, exec.commands.mask(l), .command) }
        emit(sm, "shell: \(displayShell)", .info)
        let shownEnv = exec.env.merging(exec.fileEnv).merging(stepEnv)
        if !shownEnv.isEmpty {
            emit(sm, "env:", .info)
            for (k, v) in shownEnv.pairs { emit(sm, "  \(k): \(exec.commands.mask(v.stringValue))", .info) }
        }
        emit(sm, "", .groupEnd)

        // file dello script (come fa il runner)
        let scriptFile = exec.temp.appendingPathComponent("\(UUID().uuidString.lowercased()).sh")
        try? script.write(to: scriptFile, atomically: true, encoding: .utf8)

        let files = makeCommandFiles(exec)
        var env = processEnvironment(exec: exec, scope: scope, stepEnv: stepEnv, files: files, action: step.stepId ?? "__run_\(step.index)")

        var outputs = OrderedObject()
        let outBox = OutputBox()
        let (sink, flush) = makeSink(sm, exec: exec, scope: scope, outputs: { k, v in outBox.outputs[k] = .string(v) }, state: { _, _ in })

        let state = ShellState()
        env["PWD"] = cwd.path
        for (k, v) in env { state.vars[k] = v; state.exported.insert(k) }
        state.errexit = errexit
        state.pipefail = pipefail
        state.scriptName = scriptFile.path
        let host = ShellHost()
        host.runnerOS = exec.runnerOS
        host.runnerArch = exec.runnerArch
        host.tempDir = exec.temp.path
        host.homeDir = exec.home.path
        host.gitSHA = sha
        host.gitRef = options.ref
        host.deadline = deadline
        host.isCancelled = { [weak self] in self?.interruptCurrentStep ?? true }
        let interp = ShellInterpreter(state: state, host: host)
        interp.currentStderr = sink
        let status = await interp.run(script: script, io: ShIO(stdin: InputSource.empty, stdout: sink, stderr: sink))
        flush()
        try? FileManager.default.removeItem(at: scriptFile)

        var st = OrderedObject()
        var ok = applyCommandFiles(files, exec: exec, model: sm, outputs: &outputs, state: &st)
        outputs.merge(outBox.outputs)
        if status != 0 {
            emit(sm, "##[error]Process completed with exit code \(status).", .error)
            ok = false
        }
        return (ok, outputs)
    }

    // MARK: - uses:

    private func runActionStep(uses rawUses: String, step: Step, exec: JobExecution, scope: StepScope, stepEnv: OrderedObject,
                               model sm: StepRunModel, ctx: EvaluationContext, deadline: Date) async -> (Bool, OrderedObject) {
        let uses = (try? ExpressionTemplate.evaluateString(rawUses, ctx)) ?? rawUses
        let ref: ActionReference
        do { ref = try ActionReference(uses) } catch {
            emit(sm, "##[error]\(error.localizedDescription)", .error)
            return (false, OrderedObject())
        }

        // input valutati
        var withInputs = OrderedObject()
        do {
            for (k, v) in step.with.pairs {
                withInputs[k] = .string(try ExpressionTemplate.evaluateDeep(v, ctx).stringValue)
            }
        } catch {
            emit(sm, "##[error]Errore negli input 'with': \(error.localizedDescription)", .error)
            return (false, OrderedObject())
        }

        emit(sm, "Run \(uses)", .groupStart)
        for (k, v) in withInputs.pairs { emit(sm, "with:", .info); emit(sm, "  \(k): \(exec.commands.mask(v.stringValue))", .info); break }
        if withInputs.count > 1 { for (k, v) in withInputs.pairs.dropFirst() { emit(sm, "  \(k): \(exec.commands.mask(v.stringValue))", .info) } }
        if !stepEnv.isEmpty {
            emit(sm, "env:", .info)
            for (k, v) in stepEnv.pairs { emit(sm, "  \(k): \(exec.commands.mask(v.stringValue))", .info) }
        }
        emit(sm, "", .groupEnd)

        switch ref.kind {
        case .docker(let image):
            emit(sm, "##[error]Le azioni Docker (docker://\(image)) richiedono Docker, che non può girare dentro l'app.", .error)
            return unsupported(sm)

        case .local(let path):
            let dir = exec.workspace.appendingPathComponent(path).standardizedFileURL
            do {
                let meta = try ActionMetadata.load(from: dir)
                return await runActionMetadata(meta, ref: ref, inputs: withInputs, step: step, exec: exec, scope: scope, stepEnv: stepEnv, model: sm, deadline: deadline)
            } catch {
                emit(sm, "##[error]Impossibile caricare l'azione locale '\(path)': \(error.localizedDescription). Hai eseguito actions/checkout prima?", .error)
                return (false, OrderedObject())
            }

        case .remote(let owner, let repo, let subpath, let r):
            if BuiltinActions.isEmulated(ref.key) {
                let actx = BuiltinActionContext(runner: self, exec: exec, scope: scope, model: sm, inputs: withInputs, ref: ref,
                                                stepEnv: stepEnv, sourceURL: options.sourceURL, artifactsDir: artifactsDir, sha: sha)
                let result = await BuiltinActions.run(actx)
                return (result.success, result.outputs)
            }
            do {
                var dir = try await fetcher.fetch(owner: owner, repo: repo, ref: r, log: { [weak self] in self?.emit(sm, $0, .info) })
                if let sp = subpath { dir = dir.appendingPathComponent(sp) }
                let meta = try ActionMetadata.load(from: dir)
                return await runActionMetadata(meta, ref: ref, inputs: withInputs, step: step, exec: exec, scope: scope, stepEnv: stepEnv, model: sm, deadline: deadline)
            } catch {
                emit(sm, "##[error]Impossibile preparare l'azione '\(uses)': \(error.localizedDescription)", .error)
                return (false, OrderedObject())
            }
        }
    }

    private func unsupported(_ sm: StepRunModel) -> (Bool, OrderedObject) {
        if options.unsupportedActions == .skip {
            emit(sm, "Warning: azione non supportata in locale: saltata come da impostazioni.", .warning)
            onMain { sm.note = "Saltato (non eseguibile nell'app)" }
            return (true, OrderedObject())
        }
        onMain { sm.note = "Richiede un runner reale" }
        return (false, OrderedObject())
    }

    /// Esegue un'azione dal suo action.yml (composite supportate; node/docker no).
    private func runActionMetadata(_ meta: ActionMetadata, ref: ActionReference, inputs withInputs: OrderedObject, step: Step,
                                   exec: JobExecution, scope: StepScope, stepEnv: OrderedObject, model sm: StepRunModel,
                                   deadline: Date) async -> (Bool, OrderedObject) {
        // inputs con default
        var inputsObj = OrderedObject()
        let defCtx = makeContext(exec, scope)
        for (name, spec) in meta.inputs.pairs {
            if let provided = withInputs[name] ?? withInputs.lookup(name) {
                inputsObj[name] = provided
            } else if let d = spec["default"] {
                inputsObj[name] = .string((try? ExpressionTemplate.evaluateDeep(d, defCtx).stringValue) ?? d.stringValue)
            } else {
                if spec["required"]?.isTruthy == true {
                    emit(sm, "Warning: input obbligatorio non fornito: \(name)", .warning)
                }
                inputsObj[name] = .string("")
            }
            if let dep = spec["deprecationMessage"]?.scalarString, withInputs[name] != nil {
                emit(sm, "Warning: l'input '\(name)' è deprecato: \(dep)", .warning)
            }
        }
        for (k, v) in withInputs.pairs where meta.inputs.lookup(k) == nil {
            emit(sm, "Warning: input inatteso '\(k)', input validi: \(meta.inputs.keys.joined(separator: ", "))", .warning)
            inputsObj[k] = v
        }

        if meta.isNode {
            return await runNodeAction(meta, ref: ref, inputs: inputsObj, step: step, exec: exec, stepEnv: stepEnv, model: sm, deadline: deadline)
        }
        guard meta.isComposite else {
            let kind = meta.isDocker ? "Docker" : meta.using
            emit(sm, "##[error]L'azione '\(ref.raw)' è un'azione \(kind): i container Docker non possono essere eseguiti dentro l'app.", .error)
            return unsupported(sm)
        }

        let inner = StepScope(isComposite: true)
        inner.inputs = .object(inputsObj)
        inner.actionPath = meta.directory.path
        if case .remote(let o, let r, _, let rf) = ref.kind { inner.actionRepository = "\(o)/\(r)"; inner.actionRef = rf }
        // env dello step ereditato dagli step interni
        let savedFileEnv = exec.fileEnv
        for (k, v) in stepEnv.pairs { exec.fileEnv[k] = v }
        // INPUT_* come per le azioni JavaScript
        for (k, v) in inputsObj.pairs { exec.fileEnv["INPUT_" + k.uppercased().replacingOccurrences(of: " ", with: "_")] = v }

        await runSteps(meta.steps, exec: exec, scope: inner, parentModel: sm)

        // ripristina env non modificato via GITHUB_ENV
        for (k, _) in stepEnv.pairs where exec.fileEnv[k] == stepEnv[k] { exec.fileEnv[k] = savedFileEnv[k] }
        for (k, _) in inputsObj.pairs { exec.fileEnv["INPUT_" + k.uppercased().replacingOccurrences(of: " ", with: "_")] = savedFileEnv["INPUT_" + k.uppercased()] }

        var outputs = OrderedObject()
        let outCtx = makeContext(exec, inner)
        for (name, spec) in meta.outputs.pairs {
            if let v = spec["value"]?.scalarString, let s = try? ExpressionTemplate.evaluateString(v, outCtx) { outputs[name] = .string(s) }
        }
        return (!inner.failed, outputs)
    }


    // MARK: - VM Linux

    enum EngineChoice { case vm, builtin, fail }

    /// Decide dove eseguire lo step e, se serve, avvia la VM.
    private func prepareVM(_ sm: StepRunModel) async -> EngineChoice {
        if options.shellEngine == .builtin { return .builtin }
        let vm = LinuxVM.shared
        let strict = options.shellEngine == .linux
        guard vm.isSupported else {
            if strict {
                emit(sm, "##[error]VM Linux non disponibile in questa build: \(LinuxVM.unavailabilityReason() ?? "")", .error)
                return .fail
            }
            return .builtin
        }
        var observer: UUID?
        if !vm.isReady {
            emit(sm, "Avvio della VM Linux integrata (RISC-V 64, Alpine)", .groupStart)
            // console di avvio in tempo reale nel log dello step: si vede esattamente dove si ferma
            observer = vm.observeBoot { [weak self] line in
                guard let self, !line.isEmpty, !line.hasPrefix("__AR_READY__") else { return }
                self.emit(sm, line, .info)
            }
        }
        defer { if let observer { vm.removeBootObserver(observer) } }
        let bootStart = Date()
        do {
            try await vm.boot(memoryMB: options.vmMemoryMB)
            if observer != nil {
                emit(sm, "", .groupEnd)
                emit(sm, "VM Linux pronta in \(Format.duration(Date().timeIntervalSince(bootStart)))", .info)
            }
        } catch {
            if observer != nil { emit(sm, "", .groupEnd) }
            emit(sm, (strict ? "##[error]" : "Warning: ") + "VM Linux non avviata: \(error.localizedDescription)" + (strict ? "" : " — uso l'interprete integrato."), strict ? .error : .warning)
            return strict ? .fail : .builtin
        }
        var shared = false
        onMainSync { shared = vm.has9p }
        if !shared {
            emit(sm, (strict ? "##[error]" : "Warning: ") + "La VM non ha accesso alla cartella condivisa (virtio-9p): \(strict ? "impossibile eseguire lo step." : "uso l'interprete integrato.")", strict ? .error : .warning)
            return strict ? .fail : .builtin
        }
        return .vm
    }

    /// Comando di shell secondo le regole del runner Linux di GitHub.
    private func vmShellCommand(_ spec: String) -> (template: String, display: String, ext: String)? {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        let name = trimmed.split(separator: " ").first.map(String.init) ?? ""
        if trimmed.isEmpty { return ("bash -e {0}", "/usr/bin/bash -e {0}", "sh") }
        if trimmed.contains("{0}") {
            return (trimmed, trimmed, name.hasPrefix("python") ? "py" : (name == "node" ? "js" : "sh"))
        }
        switch name {
        case "bash": return ("bash --noprofile --norc -eo pipefail {0}", "/usr/bin/bash --noprofile --norc -eo pipefail {0}", "sh")
        case "sh": return ("sh -e {0}", "/usr/bin/sh -e {0}", "sh")
        case "python", "python3": return ("python {0}", "/usr/bin/python {0}", "py")
        case "node": return ("node {0}", "/usr/bin/node {0}", "js")
        case "pwsh": return ("pwsh -command \". '{0}'\"", "pwsh -command \". '{0}'\"", "ps1")
        case "powershell", "cmd": return nil
        default: return ("\(trimmed) {0}", "\(trimmed) {0}", "sh")
        }
    }

    /// Esegue una riga di comando nella VM con l'ambiente indicato. Restituisce l'exit code.
    private func runCommandInVM(_ command: String, env: [String: String], cwd: URL, exec: JobExecution,
                                model sm: StepRunModel, deadline: Date, sink: TextSink) async -> Int32 {
        let jr = exec.root.path
        let jobRootGuest = LinuxVM.guestPath(jr)
        var w = "#!/bin/sh\n"
        w += "JR=\(LinuxVM.shQuote(jobRootGuest))\n"
        w += "if [ \"$(cat /run/ar-job 2>/dev/null)\" != \"$JR\" ]; then\n"
        w += "  umount /home/runner 2>/dev/null; mkdir -p /home/runner\n"
        w += "  mount --bind \"$JR\" /home/runner && echo \"$JR\" > /run/ar-job || { echo 'Impossibile montare la cartella del job'; exit 97; }\n"
        w += "fi\n"
        w += "cd \(LinuxVM.shQuote(LinuxVM.guestPath(cwd.path, jobRoot: jr))) || exit 98\n"
        w += "exec env -i"
        for k in env.keys.sorted() where !k.isEmpty && !k.contains("=") {
            let v = LinuxVM.translate(env[k] ?? "", jobRoot: jr)
            w += " \\\n  " + LinuxVM.shQuote("\(k)=\(v)")
        }
        w += " \\\n  /bin/sh -c " + LinuxVM.shQuote(command) + "\n"
        let wrapper = exec.temp.appendingPathComponent("ar-\(UUID().uuidString.lowercased()).sh")
        do { try w.write(to: wrapper, atomically: true, encoding: .utf8) } catch {
            emit(sm, "##[error]Impossibile preparare lo script per la VM: \(error.localizedDescription)", .error)
            return 1
        }
        defer { try? FileManager.default.removeItem(at: wrapper) }
        do {
            return try await LinuxVM.shared.run(hostScript: wrapper, jobRoot: nil, deadline: deadline,
                                                isCancelled: { [weak self] in self?.interruptCurrentStep ?? true },
                                                onLine: { line in sink.write(line + "\n") })
        } catch {
            emit(sm, "##[error]Errore della VM Linux: \(error.localizedDescription)", .error)
            return 1
        }
    }

    private func runScriptInVM(script: String, step: Step, exec: JobExecution, scope: StepScope, stepEnv: OrderedObject,
                               model sm: StepRunModel, ctx: EvaluationContext, deadline: Date) async -> (Bool, OrderedObject) {
        var shellSpec = step.shell ?? exec.defaultsRun["shell"]?.stringValue ?? ""
        if shellSpec.contains("${{") { shellSpec = (try? ExpressionTemplate.evaluateString(shellSpec, ctx)) ?? shellSpec }
        guard let shell = vmShellCommand(shellSpec) else {
            emit(sm, "##[error]La shell '\(shellSpec)' è disponibile solo su runner Windows.", .error)
            return (false, OrderedObject())
        }
        var wd = step.workingDirectory ?? exec.defaultsRun["working-directory"]?.stringValue
        if let w = wd, w.contains("${{") { wd = try? ExpressionTemplate.evaluateString(w, ctx) }
        var cwd = exec.workspace
        if let w = wd, !w.isEmpty {
            cwd = w.hasPrefix("/") ? URL(fileURLWithPath: w) : exec.workspace.appendingPathComponent(w)
        }

        let lines = script.components(separatedBy: "\n")
        emit(sm, "Run \(lines.first ?? "")", .groupStart)
        for l in lines.dropLast(script.hasSuffix("\n") ? 1 : 0) { emit(sm, exec.commands.mask(l), .command) }
        emit(sm, "shell: \(shell.display)", .info)
        let shownEnv = exec.env.merging(exec.fileEnv).merging(stepEnv)
        if !shownEnv.isEmpty {
            emit(sm, "env:", .info)
            for (k, v) in shownEnv.pairs { emit(sm, "  \(k): \(exec.commands.mask(v.stringValue))", .info) }
        }
        emit(sm, "", .groupEnd)

        let jr = exec.root.path
        let scriptFile = exec.temp.appendingPathComponent("\(UUID().uuidString.lowercased()).\(shell.ext)")
        do { try LinuxVM.translate(script, jobRoot: jr).write(to: scriptFile, atomically: true, encoding: .utf8) } catch {
            emit(sm, "##[error]\(error.localizedDescription)", .error)
            return (false, OrderedObject())
        }
        defer { try? FileManager.default.removeItem(at: scriptFile) }

        let files = makeCommandFiles(exec)
        var env = processEnvironment(exec: exec, scope: scope, stepEnv: stepEnv, files: files, action: step.stepId ?? "__run_\(step.index)")
        env["HOME"] = exec.root.path
        env["PWD"] = cwd.path
        let outBox = OutputBox()
        let (sink, flush) = makeSink(sm, exec: exec, scope: scope, outputs: { k, v in outBox.outputs[k] = .string(v) }, state: { _, _ in })
        let command = shell.template.replacingOccurrences(of: "{0}", with: LinuxVM.shQuote(LinuxVM.guestPath(scriptFile.path, jobRoot: jr)))
        let status = await runCommandInVM(command, env: env, cwd: cwd, exec: exec, model: sm, deadline: deadline, sink: sink)
        flush()

        var outputs = OrderedObject()
        var st = OrderedObject()
        var ok = applyCommandFiles(files, exec: exec, model: sm, outputs: &outputs, state: &st)
        outputs.merge(outBox.outputs)
        if status != 0 {
            emit(sm, "##[error]Process completed with exit code \(status).", .error)
            ok = false
        }
        return (ok, outputs)
    }

    /// Azioni JavaScript (runs.using: node*): eseguite con il Node.js della VM, come fa il runner.
    private func runNodeAction(_ meta: ActionMetadata, ref: ActionReference, inputs: OrderedObject, step: Step, exec: JobExecution,
                               stepEnv: OrderedObject, model sm: StepRunModel, deadline: Date) async -> (Bool, OrderedObject) {
        guard let main = meta.main else {
            emit(sm, "##[error]action.yml non specifica runs.main", .error)
            return (false, OrderedObject())
        }
        let previousEngine = options.shellEngine
        if previousEngine == .builtin {
            emit(sm, "##[error]L'azione '\(ref.raw)' è un'azione JavaScript (\(meta.using)): serve la VM Linux (impostazione motore: interprete integrato).", .error)
            return unsupported(sm)
        }
        switch await prepareVM(sm) {
        case .vm: break
        default:
            emit(sm, "##[error]L'azione JavaScript '\(ref.raw)' richiede Node.js nella VM Linux, che non è disponibile.", .error)
            return unsupported(sm)
        }
        let actionScope = StepScope(isComposite: true)
        actionScope.actionPath = meta.directory.path
        if case .remote(let o, let r, _, let rf) = ref.kind { actionScope.actionRepository = "\(o)/\(r)"; actionScope.actionRef = rf }
        let stateKey = "\(ref.key)#\(step.index)#\(UUID().uuidString)"

        func runPhase(_ script: String, model pm: StepRunModel, state: OrderedObject, deadline: Date) async -> (Bool, OrderedObject, OrderedObject) {
            let files = makeCommandFiles(exec)
            var env = processEnvironment(exec: exec, scope: actionScope, stepEnv: stepEnv, files: files, action: step.stepId ?? "__\(ref.key)")
            env["HOME"] = exec.root.path
            for (k, v) in inputs.pairs {
                env["INPUT_" + k.replacingOccurrences(of: " ", with: "_").uppercased()] = v.stringValue
            }
            for (k, v) in state.pairs { env["STATE_" + k] = v.stringValue }
            let outBox = OutputBox()
            let stateBox = OutputBox()
            let (sink, flush) = makeSink(pm, exec: exec, scope: actionScope, outputs: { k, v in outBox.outputs[k] = .string(v) },
                                         state: { k, v in stateBox.outputs[k] = .string(v) })
            let path = LinuxVM.guestPath(meta.directory.appendingPathComponent(script).path, jobRoot: exec.root.path)
            let status = await runCommandInVM("node \(LinuxVM.shQuote(path))", env: env, cwd: exec.workspace, exec: exec,
                                              model: pm, deadline: deadline, sink: sink)
            flush()
            var outputs = OrderedObject()
            var st = OrderedObject()
            var ok = applyCommandFiles(files, exec: exec, model: pm, outputs: &outputs, state: &st)
            outputs.merge(outBox.outputs)
            st.merge(stateBox.outputs)
            if status != 0 {
                emit(pm, "##[error]Node.js ha terminato con exit code \(status).", .error)
                ok = false
            }
            return (ok, outputs, st)
        }

        var state = OrderedObject()
        if let pre = meta.pre {
            var c = makeContext(exec, actionScope)
            c.status = StatusState(succeeded: !exec.failed, failed: exec.failed, cancelled: cancelled)
            if (try? ExpressionTemplate.evaluateCondition(meta.preIf ?? "always()", c)) ?? true {
                let (_, _, s) = await runPhase(pre, model: sm, state: state, deadline: deadline)
                state.merge(s)
            }
        }
        emit(sm, "Esecuzione di \(meta.name) con Node.js nella VM Linux (\(meta.using))", .info)
        let (ok, outputs, s) = await runPhase(main, model: sm, state: state, deadline: deadline)
        state.merge(s)
        exec.actionState[stateKey] = state

        if let post = meta.post {
            let condition = meta.postIf ?? "always()"
            let savedState = state
            exec.postSteps.append((name: "Post \(sm.name)", condition: condition, run: { [weak self] pm in
                guard let self = self else { return false }
                let (pok, _, _) = await runPhase(post, model: pm, state: savedState, deadline: exec.deadline)
                _ = self
                return pok
            }))
        }
        return (ok, outputs)
    }

    // MARK: - Reusable workflow

    private func runReusableWorkflow(_ job: Job, uses: String, github: OrderedObject, inputs: JSONValue, needs: OrderedObject,
                                     model jm: JobRunModel) async -> (result: String, outputs: OrderedObject) {
        appendJobLine(jm, "Chiamata al reusable workflow \(uses)", .info)
        var calledURL: URL? = nil
        var sourceForCalled = options.sourceURL
        if uses.hasPrefix("./") {
            calledURL = options.sourceURL.appendingPathComponent(String(uses.dropFirst(2)))
        } else if let ref = try? ActionReference(uses), case .remote(let o, let r, let p, let rf) = ref.kind, let path = p {
            do {
                let dir = try await fetcher.fetch(owner: o, repo: r, ref: rf, log: { [weak self] s in self?.appendJobLine(jm, s, .info) })
                calledURL = dir.appendingPathComponent(path)
                sourceForCalled = dir
            } catch {
                appendJobLine(jm, "Impossibile scaricare \(uses): \(error.localizedDescription)", .error)
            }
        }
        guard let url = calledURL, let text = try? String(contentsOf: url, encoding: .utf8),
              let called = try? WorkflowParser.parse(text: text, path: uses) else {
            appendJobLine(jm, "Reusable workflow non trovato o non valido: \(uses)", .error)
            completeJob(jm, .failure)
            return ("failure", OrderedObject())
        }
        guard called.isReusable else {
            appendJobLine(jm, "\(uses) non dichiara 'on: workflow_call'", .error)
            completeJob(jm, .failure)
            return ("failure", OrderedObject())
        }
        var ctx = EvaluationContext()
        ctx["github"] = .object(github)
        ctx["needs"] = .object(needs)
        ctx["inputs"] = inputs
        ctx["vars"] = .object(stringsObject(options.variables))
        ctx["secrets"] = .object(secretsObject())
        var callInputs: [String: String] = [:]
        if let w = job.with, let evaluated = try? ExpressionTemplate.evaluateDeep(w, ctx), let o = evaluated.objectValue {
            for (k, v) in o.pairs { callInputs[k] = v.stringValue }
        }
        var callSecrets: [String: String] = [:]
        if job.secrets?.stringValue == "inherit" { callSecrets = options.secrets }
        else if let s = job.secrets, let ev = try? ExpressionTemplate.evaluateDeep(s, ctx), let o = ev.objectValue {
            for (k, v) in o.pairs { callSecrets[k] = v.stringValue }
        }
        var opts = options
        opts.sourceURL = sourceForCalled
        opts.eventName = "workflow_call"
        opts.inputs = callInputs
        opts.secrets = callSecrets
        opts.onlyJob = nil
        let nestedModel = LocalRunModel(title: called.name, workflowPath: uses, event: "workflow_call", runNumber: options.runNumber)
        let nested = LocalWorkflowRunner(workflow: called, options: opts, model: nestedModel)
        nested.sha = sha
        nested.runId = runId
        appendJobLine(jm, "Esecuzione dei job di '\(called.name)'…", .info)
        onMain { jm.status = .inProgress; jm.startedAt = Date() }
        await nested.run()
        // riporta i job annidati nella UI sotto il job chiamante
        onMain {
            let nestedJobs = nestedModel.jobs
            for nj in nestedJobs { nj.name = "\(jm.name) / \(nj.name)" }
            if let idx = self.model.jobs.firstIndex(where: { $0 === jm }) { self.model.jobs.insert(contentsOf: nestedJobs, at: idx + 1) }
            self.model.annotations.append(contentsOf: nestedModel.annotations)
        }
        // output del workflow chiamato
        var jobsCtx = OrderedObject()
        for (id, r) in nested.jobResults {
            jobsCtx[id] = .object(OrderedObject([("result", .string(r.result)), ("outputs", .object(r.outputs))]))
        }
        var outCtx = EvaluationContext()
        outCtx["jobs"] = .object(jobsCtx)
        outCtx["inputs"] = .object(OrderedObject(callInputs.map { ($0.key, JSONValue.string($0.value)) }))
        var outputs = OrderedObject()
        if let outs = called.triggers["workflow_call"]?["outputs"]?.objectValue {
            for (k, spec) in outs.pairs {
                if let v = spec["value"]?.scalarString, let s = try? ExpressionTemplate.evaluateString(v, outCtx) { outputs[k] = .string(s) }
            }
        }
        let failed = nested.jobResults.values.contains { $0.result == "failure" }
        completeJob(jm, failed ? .failure : (nested.cancelled ? .cancelled : .success))
        let outDict = Dictionary(uniqueKeysWithValues: outputs.pairs.map { ($0.key, $0.value.stringValue) })
        onMain { jm.outputs = outDict }
        return (failed ? "failure" : "success", outputs)
    }
}

final class OutputBox {
    var outputs = OrderedObject()
}

enum UIDeviceInfo {
    static var name: String { ProcessInfo.processInfo.hostName }
}
