import Foundation

enum WorkflowParser {
    struct ParseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let knownWorkflowKeys: Set<String> = [
        "name", "run-name", "on", "permissions", "env", "defaults", "concurrency", "jobs"
    ]
    static let knownJobKeys: Set<String> = [
        "name", "permissions", "needs", "if", "runs-on", "snapshot", "environment", "concurrency", "outputs",
        "env", "defaults", "steps", "timeout-minutes", "strategy", "continue-on-error", "container",
        "services", "uses", "with", "secrets"
    ]
    static let knownStepKeys: Set<String> = [
        "id", "if", "name", "uses", "run", "shell", "with", "env", "working-directory",
        "continue-on-error", "timeout-minutes"
    ]
    static let knownEvents: Set<String> = [
        "branch_protection_rule", "check_run", "check_suite", "create", "delete", "deployment",
        "deployment_status", "discussion", "discussion_comment", "fork", "gollum", "image_version",
        "issue_comment", "issues", "label", "merge_group", "milestone", "page_build", "public",
        "pull_request", "pull_request_review", "pull_request_review_comment", "pull_request_target",
        "push", "registry_package", "release", "repository_dispatch", "schedule", "status", "watch",
        "workflow_call", "workflow_dispatch", "workflow_run"
    ]

    static func parse(text: String, path: String) throws -> Workflow {
        let root = try YAMLLoader.load(text)
        guard let object = root.objectValue else {
            throw ParseError(message: "\(path): il documento deve essere una mappa YAML")
        }
        var diagnostics: [Diagnostic] = []

        for key in object.keys where !knownWorkflowKeys.contains(key) {
            diagnostics.append(Diagnostic(severity: .error, message: "Chiave sconosciuta '\(key)' a livello di workflow", location: path))
        }

        let triggers = normalizeTriggers(object["on"], diagnostics: &diagnostics, path: path)
        var jobs: [Job] = []
        if let jobsObj = object["jobs"]?.objectValue {
            for (id, value) in jobsObj.pairs {
                guard let jobRaw = value.objectValue else {
                    diagnostics.append(Diagnostic(severity: .error, message: "Il job '\(id)' deve essere una mappa", location: path))
                    continue
                }
                jobs.append(Job(id: id, raw: jobRaw))
            }
        } else {
            diagnostics.append(Diagnostic(severity: .error, message: "Manca la sezione 'jobs'", location: path))
        }

        let fileName = (path as NSString).lastPathComponent
        let name = object["name"]?.scalarString ?? path
        var workflow = Workflow(
            path: path,
            fileName: fileName,
            raw: object,
            name: name,
            runName: object["run-name"]?.scalarString,
            triggers: triggers,
            env: object["env"],
            defaults: object["defaults"],
            permissions: object["permissions"],
            concurrency: object["concurrency"],
            jobs: jobs,
            diagnostics: diagnostics
        )
        workflow.diagnostics.append(contentsOf: WorkflowValidator.validate(workflow))
        return workflow
    }

    static func normalizeTriggers(_ value: JSONValue?, diagnostics: inout [Diagnostic], path: String) -> OrderedObject {
        var result = OrderedObject()
        switch value {
        case .string(let s)?:
            result[s] = .null
        case .array(let a)?:
            for v in a { if let s = v.scalarString { result[s] = .null } }
        case .object(let o)?:
            result = o
        default:
            diagnostics.append(Diagnostic(severity: .error, message: "Manca la sezione 'on' (eventi di attivazione)", location: path))
        }
        for event in result.keys where !knownEvents.contains(event) {
            diagnostics.append(Diagnostic(severity: .warning, message: "Evento sconosciuto '\(event)'", location: path))
        }
        return result
    }

    /// Carica tutti i workflow da una cartella repo.
    static func loadWorkflows(in repoURL: URL) -> (workflows: [Workflow], errors: [Diagnostic]) {
        let dir = repoURL.appendingPathComponent(".github/workflows", isDirectory: true)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return ([], []) }
        var workflows: [Workflow] = []
        var errors: [Diagnostic] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where ["yml", "yaml"].contains(file.pathExtension.lowercased()) {
            let rel = ".github/workflows/" + file.lastPathComponent
            do {
                let text = try String(contentsOf: file, encoding: .utf8)
                workflows.append(try parse(text: text, path: rel))
            } catch {
                errors.append(Diagnostic(severity: .error, message: error.localizedDescription, location: rel))
            }
        }
        return (workflows, errors)
    }
}

enum WorkflowValidator {
    static let idPattern = try! NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_-]*$")

    static func isValidId(_ s: String) -> Bool {
        idPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func validate(_ wf: Workflow) -> [Diagnostic] {
        var d: [Diagnostic] = []
        let loc = wf.path
        let ids = Set(wf.jobs.map { $0.id })
        if wf.jobs.isEmpty { d.append(Diagnostic(severity: .error, message: "Nessun job definito", location: loc)) }

        for job in wf.jobs {
            let jl = "\(loc) › jobs.\(job.id)"
            if !isValidId(job.id) {
                d.append(Diagnostic(severity: .error, message: "ID job non valido '\(job.id)': deve iniziare con lettera o '_' e contenere solo alfanumerici, '-' o '_'", location: jl))
            }
            for key in job.raw.keys where !WorkflowParser.knownJobKeys.contains(key) {
                d.append(Diagnostic(severity: .error, message: "Chiave sconosciuta '\(key)' nel job", location: jl))
            }
            for need in job.needs where !ids.contains(need) {
                d.append(Diagnostic(severity: .error, message: "'needs' fa riferimento a un job inesistente: '\(need)'", location: jl))
            }
            if job.uses != nil {
                if job.raw["steps"] != nil {
                    d.append(Diagnostic(severity: .error, message: "Un job che chiama un reusable workflow ('uses') non può avere 'steps'", location: jl))
                }
                if job.raw["runs-on"] != nil {
                    d.append(Diagnostic(severity: .error, message: "Un job con 'uses' non può avere 'runs-on'", location: jl))
                }
                continue
            }
            if job.runsOn == nil {
                d.append(Diagnostic(severity: .error, message: "Manca 'runs-on'", location: jl))
            }
            if job.raw["steps"]?.arrayValue?.isEmpty ?? true {
                d.append(Diagnostic(severity: .error, message: "Il job non ha 'steps'", location: jl))
            }
            if let label = job.runsOn?.scalarString, label.contains("windows") {
                d.append(Diagnostic(severity: .warning, message: "Runner Windows: eseguibile solo in modalità GitHub (cloud)", location: jl))
            }
            if job.container != nil || job.services != nil {
                d.append(Diagnostic(severity: .info, message: "container/services richiedono Docker: in locale verranno ignorati, usa l'esecuzione su GitHub per la fedeltà completa", location: jl))
            }
            var stepIds = Set<String>()
            for step in job.steps {
                let sl = "\(jl) › steps[\(step.index)]"
                for key in step.raw.keys where !WorkflowParser.knownStepKeys.contains(key) {
                    d.append(Diagnostic(severity: .error, message: "Chiave sconosciuta '\(key)' nello step", location: sl))
                }
                if step.uses == nil && step.run == nil {
                    d.append(Diagnostic(severity: .error, message: "Lo step deve avere 'uses' oppure 'run'", location: sl))
                }
                if step.uses != nil && step.run != nil {
                    d.append(Diagnostic(severity: .error, message: "Lo step non può avere sia 'uses' che 'run'", location: sl))
                }
                if step.uses != nil && step.shell != nil {
                    d.append(Diagnostic(severity: .error, message: "'shell' è valido solo con 'run'", location: sl))
                }
                if let sid = step.stepId {
                    if !isValidId(sid) {
                        d.append(Diagnostic(severity: .error, message: "ID step non valido '\(sid)'", location: sl))
                    }
                    if stepIds.contains(sid) {
                        d.append(Diagnostic(severity: .error, message: "ID step duplicato '\(sid)'", location: sl))
                    }
                    stepIds.insert(sid)
                }
                if let uses = step.uses, !uses.hasPrefix("./"), !uses.hasPrefix("docker://"), !uses.contains("@") {
                    d.append(Diagnostic(severity: .error, message: "'uses: \(uses)' deve specificare una versione (@ref)", location: sl))
                }
            }
        }

        if let cycle = JobGraph.findCycle(wf.jobs) {
            d.append(Diagnostic(severity: .error, message: "Dipendenza circolare tra job: \(cycle.joined(separator: " → "))", location: loc))
        }

        // Verifica sintattica delle espressioni
        for (path, text) in collectStrings(.object(wf.raw), path: "") {
            for expr in ExpressionTemplate.extractExpressions(text) {
                do { _ = try ExpressionParser.parse(expr) } catch {
                    d.append(Diagnostic(severity: .error, message: "Espressione non valida '${{ \(expr) }}': \(error.localizedDescription)", location: "\(loc) › \(path)"))
                }
            }
        }
        for job in wf.jobs {
            if let c = job.ifCondition, !c.contains("${{") {
                do { _ = try ExpressionParser.parse(c) } catch {
                    d.append(Diagnostic(severity: .error, message: "Condizione 'if' non valida: \(error.localizedDescription)", location: "\(loc) › jobs.\(job.id).if"))
                }
            }
            for step in job.steps {
                if let c = step.ifCondition, !c.contains("${{") {
                    do { _ = try ExpressionParser.parse(c) } catch {
                        d.append(Diagnostic(severity: .error, message: "Condizione 'if' non valida: \(error.localizedDescription)", location: "\(loc) › jobs.\(job.id).steps[\(step.index)].if"))
                    }
                }
            }
        }
        return d
    }

    private static func collectStrings(_ v: JSONValue, path: String) -> [(String, String)] {
        switch v {
        case .string(let s): return s.contains("${{") ? [(path, s)] : []
        case .array(let a):
            return a.enumerated().flatMap { collectStrings($0.element, path: "\(path)[\($0.offset)]") }
        case .object(let o):
            return o.pairs.flatMap { collectStrings($0.value, path: path.isEmpty ? $0.key : "\(path).\($0.key)") }
        default: return []
        }
    }
}
