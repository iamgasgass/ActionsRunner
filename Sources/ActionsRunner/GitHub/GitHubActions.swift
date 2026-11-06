import Foundation

/// Operazioni di GitHub Actions: avvio (workflow_dispatch / push), ricerca della run,
/// sincronizzazione di secrets e variabili, controllo della run.
struct GitHubActions {
    let api: GitHubAPI
    let repo: String
    private var base: String { GHPath.repo(repo) }

    // MARK: Repository

    func repository() async throws -> GHRepo {
        do {
            return try await api.get(base)
        } catch let e as GitHubError where e.isNotFound {
            throw GitHubError(status: 404, message: "repository \(repo) non trovato o non visibile con questo token")
        }
    }

    static func listRepositories(api: GitHubAPI) async throws -> [GHRepo] {
        let pages = try await api.pages("/user/repos", query: ["sort": "pushed", "affiliation": "owner,collaborator,organization_member"], maxPages: 3)
        var out: [GHRepo] = []
        for p in pages { out += try api.decode([GHRepo].self, p) }
        return out.filter { $0.archived != true }
    }

    static func createRepository(api: GitHubAPI, name: String, isPrivate: Bool) async throws -> GHRepo {
        do {
            return try await api.post("/user/repos", json: [
                "name": name, "private": isPrivate, "auto_init": true,
                "description": "Creato da ActionsRunner per iOS",
            ])
        } catch let e as GitHubError where e.status == 422 {
            throw GitHubError(status: 422, message: "impossibile creare '\(name)': \(e.message). Esiste già un repository con questo nome? Selezionalo dall'elenco.")
        } catch let e as GitHubError where e.status == 403 || e.status == 404 {
            throw GitHubError(status: e.status, message: "il token non può creare repository (serve lo scope 'repo' o, per i token fine-grained, 'Administration: Read and write'): \(e.message)")
        }
    }

    // MARK: Avvio

    /// Avvia un workflow con workflow_dispatch. Restituisce l'ID della run se GitHub lo comunica
    /// (parametro return_run_details, disponibile da febbraio 2026), altrimenti nil.
    func dispatch(workflowFile: String, ref: String, inputs: [String: String], log: (String) -> Void) async throws -> Int? {
        var body: [String: Any] = ["ref": ref, "return_run_details": true]
        if !inputs.isEmpty { body["inputs"] = inputs }
        let path = "\(base)/actions/workflows/\(GHPath.escape(workflowFile))/dispatches"
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, http) = try await api.send("POST", path, json: body)
                if http.statusCode == 204 || data.isEmpty { return nil }
                return GitHubActions.runId(fromDispatchResponse: data)
            } catch let e as GitHubError {
                let m = e.message.lowercased()
                // parametro non riconosciuto (API più vecchie, es. GitHub Enterprise): si riprova senza
                if e.status == 422, m.contains("return_run_details"), body["return_run_details"] != nil {
                    body.removeValue(forKey: "return_run_details")
                    continue
                }
                // un workflow appena caricato può non essere ancora registrato: si riprova per ~40 s
                if (e.status == 404 || (e.status == 422 && m.contains("workflow_dispatch"))) && attempt < 9 {
                    if attempt == 1 { log("Attendo che GitHub registri il workflow…") }
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    continue
                }
                if e.status == 422 && m.contains("workflow_dispatch") {
                    throw GitHubError(status: 422, message: "il workflow non dichiara 'on: workflow_dispatch' nel branch \(ref): avvialo con un push.")
                }
                if e.status == 422 && m.contains("input") {
                    throw GitHubError(status: 422, message: "input non validi per il workflow: \(e.message)")
                }
                if e.status == 403 || e.status == 404 {
                    throw GitHubError(status: e.status, message: "impossibile avviare il workflow: il token deve avere lo scope 'workflow' (classic) o 'Actions: Read and write' (fine-grained). \(e.message)")
                }
                throw e
            }
        }
    }

    static func runId(fromDispatchResponse data: Data) -> Int? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for k in ["workflow_run_id", "run_id", "id"] {
            if let n = obj[k] as? Int { return n }
            if let n = obj[k] as? NSNumber { return n.intValue }
        }
        for k in ["run_url", "url", "html_url"] {
            if let s = obj[k] as? String, let r = s.range(of: "/runs/") {
                let digits = s[r.upperBound...].prefix { $0.isNumber }
                if let n = Int(digits) { return n }
            }
        }
        return nil
    }

    /// Cerca la run del workflow creata per un commit (push) o dopo un dispatch.
    func findRun(workflowPath: String, headSha: String?, event: String, branch: String, notBefore: Date,
                 timeout: TimeInterval, isCancelled: () -> Bool) async throws -> GHRun? {
        let limit = Date().addingTimeInterval(timeout)
        var delay: UInt64 = 2_000_000_000
        while Date() < limit {
            if isCancelled() { throw CancellationError() }
            var query = ["event": event, "per_page": "30"]
            if let headSha { query["head_sha"] = headSha } else { query["branch"] = branch }
            let page: GHRunsPage = try await api.get("\(base)/actions/runs", query: query)
            let candidates = page.workflowRuns.filter { run in
                let p = (run.path ?? "").components(separatedBy: "@").first ?? ""
                let created = GHDate.parse(run.createdAt) ?? .distantPast
                return (p == workflowPath || p.isEmpty) && created >= notBefore.addingTimeInterval(-90)
            }
            if let r = candidates.sorted(by: { $0.id > $1.id }).first(where: { ($0.path ?? "").hasPrefix(workflowPath) }) ?? candidates.first {
                return r
            }
            try await Task.sleep(nanoseconds: delay)
            delay = min(delay + 1_000_000_000, 5_000_000_000)
        }
        return nil
    }

    // MARK: Controllo

    func run(_ id: Int) async throws -> GHRun { try await api.get("\(base)/actions/runs/\(id)") }

    func jobs(runId: Int) async throws -> [GHJob] {
        var all: [GHJob] = []
        for p in try await api.pages("\(base)/actions/runs/\(runId)/jobs", query: ["filter": "latest"], maxPages: 10) {
            all += try api.decode(GHJobsPage.self, p).jobs
        }
        return all
    }

    func artifacts(runId: Int) async throws -> [GHArtifact] {
        var all: [GHArtifact] = []
        for p in try await api.pages("\(base)/actions/runs/\(runId)/artifacts", maxPages: 5) {
            all += try api.decode(GHArtifactsPage.self, p).artifacts
        }
        return all
    }

    func annotations(jobId: Int) async throws -> [GHAnnotation] {
        try await api.get("\(base)/check-runs/\(jobId)/annotations", query: ["per_page": "100"])
    }

    func jobLog(jobId: Int) async throws -> String {
        try await api.downloadText("\(base)/actions/jobs/\(jobId)/logs")
    }

    func cancel(runId: Int, force: Bool) async throws {
        try await api.send("POST", "\(base)/actions/runs/\(runId)/\(force ? "force-cancel" : "cancel")")
    }

    func rerun(runId: Int, failedOnly: Bool, debug: Bool) async throws {
        try await api.send("POST", "\(base)/actions/runs/\(runId)/\(failedOnly ? "rerun-failed-jobs" : "rerun")",
                           json: debug ? ["enable_debug_logging": true] as [String: Any] : nil)
    }

    func downloadArtifact(_ a: GHArtifact) async throws -> URL {
        try await api.download("\(base)/actions/artifacts/\(a.id)/zip")
    }

    // MARK: Secrets e variabili

    static func isValidName(_ n: String) -> Bool {
        guard let f = n.first, !f.isNumber, !n.uppercased().hasPrefix("GITHUB_") else { return false }
        return n.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// Copia nel repository i secrets e le variabili configurati nell'app (cifratura sealed box di libsodium).
    func syncSecretsAndVariables(secrets: [String: String], variables: [String: String], log: (String) -> Void) async throws {
        if !secrets.isEmpty {
            let key: GHPublicKey
            do {
                key = try await api.get("\(base)/actions/secrets/public-key")
            } catch let e as GitHubError where e.status == 403 || e.status == 404 {
                throw GitHubError(status: e.status, message: "il token non può gestire i secrets del repository (scope 'repo' o permesso 'Secrets: Read and write'): \(e.message)")
            }
            guard let pk = Data(base64Encoded: key.key) else { throw GitHubError(status: 0, message: "chiave pubblica dei secrets non valida") }
            for (name, value) in secrets.sorted(by: { $0.key < $1.key }) {
                guard GitHubActions.isValidName(name) else { log("Secret '\(name)' ignorato: nome non valido per GitHub"); continue }
                let sealed = try SealedBox.seal(Data(value.utf8), recipientPublicKey: pk)
                try await api.send("PUT", "\(base)/actions/secrets/\(name)",
                                   json: ["encrypted_value": sealed.base64EncodedString(), "key_id": key.keyId])
            }
            log("Secrets sincronizzati: \(secrets.keys.filter(GitHubActions.isValidName).sorted().joined(separator: ", "))")
        }
        if !variables.isEmpty {
            for (name, value) in variables.sorted(by: { $0.key < $1.key }) {
                guard GitHubActions.isValidName(name) else { log("Variabile '\(name)' ignorata: nome non valida per GitHub"); continue }
                do {
                    try await api.send("PATCH", "\(base)/actions/variables/\(name)", json: ["name": name, "value": value])
                } catch let e as GitHubError where e.isNotFound {
                    try await api.send("POST", "\(base)/actions/variables", json: ["name": name, "value": value])
                }
            }
            log("Variabili sincronizzate: \(variables.keys.filter(GitHubActions.isValidName).sorted().joined(separator: ", "))")
        }
    }
}

// MARK: - Log dei job

/// Log di un job di GitHub diviso per step usando gli orari (ogni riga ha un timestamp,
/// ogni step ha inizio e fine).
enum GitHubJobLog {
    struct Line {
        let date: Date?
        let line: LogLine
    }

    static func parse(_ text: String) -> [Line] {
        var out: [Line] = []
        var id = 0
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        for raw in lines {
            var line = raw
            if line.hasSuffix("\r") { line.removeLast() }
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            var date: Date?
            if line.count > 20, line.dropFirst(4).first == "-", line.dropFirst(10).first == "T",
               let space = line.firstIndex(of: " "), line.distance(from: line.startIndex, to: space) <= 34 {
                date = GHDate.parse(String(line[..<space]))
                if date != nil { line = String(line[line.index(after: space)...]) }
            }
            var kind: LogLine.Kind = .output
            if line.hasPrefix("##[group]") { kind = .groupStart; line = String(line.dropFirst(9)) }
            else if line.hasPrefix("##[endgroup]") { kind = .groupEnd; line = "" }
            else if line.hasPrefix("##[error]") { kind = .error; line = String(line.dropFirst(9)) }
            else if line.hasPrefix("##[warning]") { kind = .warning; line = String(line.dropFirst(11)) }
            else if line.hasPrefix("##[notice]") { kind = .notice; line = String(line.dropFirst(10)) }
            else if line.hasPrefix("##[debug]") { kind = .debug; line = String(line.dropFirst(9)) }
            else if line.hasPrefix("##[command]") { kind = .command; line = String(line.dropFirst(11)) }
            else if line.hasPrefix("[command]") { kind = .command; line = String(line.dropFirst(9)) }
            else if line.hasPrefix("##[section]") { kind = .section; line = String(line.dropFirst(11)) }
            out.append(Line(date: date, line: LogLine(id: id, text: line, kind: kind, date: date ?? Date())))
            id += 1
        }
        return out
    }

    /// Assegna ogni riga allo step in corso in quel momento (ultimo step iniziato non dopo la riga).
    static func split(_ lines: [Line], steps: [GHStep]) -> [Int: [LogLine]] {
        let starts: [(number: Int, start: Date)] = steps.compactMap { s in
            GHDate.parse(s.startedAt).map { (s.number, $0) }
        }.sorted { $0.start == $1.start ? $0.number < $1.number : $0.start < $1.start }
        guard let first = starts.first else { return [:] }
        var out: [Int: [LogLine]] = [:]
        var current = first.number
        var idx = 0
        for l in lines {
            if let d = l.date {
                let floored = Date(timeIntervalSince1970: floor(d.timeIntervalSince1970))
                while idx + 1 < starts.count, starts[idx + 1].start <= floored { idx += 1 }
                current = starts[idx].number
            }
            out[current, default: []].append(l.line)
        }
        return out
    }
}
