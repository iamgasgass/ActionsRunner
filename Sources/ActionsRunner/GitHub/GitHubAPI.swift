import Foundation

struct GitHubError: LocalizedError {
    let status: Int
    let message: String
    var documentationURL: String? = nil
    var errors: String? = nil

    var errorDescription: String? {
        var s = "GitHub API \(status): \(message)"
        if let e = errors, !e.isEmpty { s += " — \(e)" }
        switch status {
        case 401: s += "\nIl token non è valido o è scaduto."
        case 403 where message.lowercased().contains("workflow"):
            s += "\nIl token deve avere lo scope 'workflow' (classic) o il permesso 'Workflows: Read and write' (fine-grained) per caricare file in .github/workflows."
        case 403, 404:
            s += "\nVerifica che il token abbia accesso al repository (Contents, Actions, Workflows: read & write)."
        default: break
        }
        return s
    }
}

/// Client REST minimale per api.github.com (versione API 2022-11-28).
final class GitHubAPI {
    let token: String?
    let baseURL: URL
    let session: URLSession
    static let apiVersion = "2022-11-28"

    init(token: String?, baseURL: URL = URL(string: "https://api.github.com")!) {
        self.token = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = baseURL
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 600
        cfg.httpAdditionalHeaders = ["User-Agent": "ActionsRunner-iOS/1.0"]
        session = URLSession(configuration: cfg)
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    func makeRequest(_ method: String, _ path: String, query: [String: String] = [:], body: Any? = nil,
                     accept: String = "application/vnd.github+json") throws -> URLRequest {
        var comps: URLComponents
        if path.hasPrefix("http") {
            guard let c = URLComponents(string: path) else { throw GitHubError(status: 0, message: "URL non valido: \(path)") }
            comps = c
        } else {
            guard let c = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
                throw GitHubError(status: 0, message: "Percorso non valido: \(path)")
            }
            comps = c
        }
        if !query.isEmpty {
            comps.queryItems = (comps.queryItems ?? []) + query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw GitHubError(status: 0, message: "URL non valido") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue(GitHubAPI.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        if let t = token, !t.isEmpty { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let b = body {
            req.httpBody = try JSONSerialization.data(withJSONObject: b, options: [])
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    /// Esegue la richiesta con retry su rate-limit secondario (403/429 + Retry-After) ed errori 5xx.
    @discardableResult
    func send(_ method: String, _ path: String, query: [String: String] = [:], body: Any? = nil,
              accept: String = "application/vnd.github+json", allow: Set<Int> = []) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            attempt += 1
            let req = try makeRequest(method, path, query: query, body: body, accept: accept)
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw GitHubError(status: 0, message: "Risposta non HTTP") }
            if (200..<300).contains(http.statusCode) || allow.contains(http.statusCode) { return (data, http) }

            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0) }
            let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining")
            let isRateLimited = http.statusCode == 429 || (http.statusCode == 403 && (retryAfter != nil || remaining == "0"))
            if attempt <= 4, isRateLimited || (500...599).contains(http.statusCode) {
                var wait = retryAfter ?? pow(2, Double(attempt))
                if remaining == "0", let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap({ Double($0) }) {
                    wait = max(wait, reset - Date().timeIntervalSince1970 + 1)
                }
                wait = min(wait, 90)
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                continue
            }
            throw GitHubAPI.error(from: data, status: http.statusCode)
        }
    }

    static func error(from data: Data, status: Int) -> GitHubError {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let msg = obj?["message"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self)
        var errs: String? = nil
        if let arr = obj?["errors"] as? [Any] {
            errs = arr.map { e -> String in
                if let d = e as? [String: Any] { return (d["message"] as? String) ?? (d["code"] as? String) ?? "\(d)" }
                return "\(e)"
            }.joined(separator: "; ")
        }
        return GitHubError(status: status, message: msg, documentationURL: obj?["documentation_url"] as? String, errors: errs)
    }

    func get<T: Decodable>(_ type: T.Type, _ path: String, query: [String: String] = [:]) async throws -> T {
        let (data, _) = try await send("GET", path, query: query)
        return try GitHubAPI.decoder.decode(T.self, from: data)
    }

    func post<T: Decodable>(_ type: T.Type, _ path: String, body: Any) async throws -> T {
        let (data, _) = try await send("POST", path, body: body)
        return try GitHubAPI.decoder.decode(T.self, from: data)
    }

    func patch<T: Decodable>(_ type: T.Type, _ path: String, body: Any) async throws -> T {
        let (data, _) = try await send("PATCH", path, body: body)
        return try GitHubAPI.decoder.decode(T.self, from: data)
    }

    /// Scarica un file seguendo i redirect (log, artifact, zipball).
    func download(_ path: String, to destination: URL, accept: String = "application/vnd.github+json") async throws {
        let req = try makeRequest("GET", path, accept: accept)
        let (tmp, resp) = try await session.download(for: req)
        guard let http = resp as? HTTPURLResponse else { throw GitHubError(status: 0, message: "Risposta non HTTP") }
        guard (200..<300).contains(http.statusCode) else {
            let data = (try? Data(contentsOf: tmp)) ?? Data()
            throw GitHubAPI.error(from: data, status: http.statusCode)
        }
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: tmp, to: destination)
    }

    func text(_ path: String, accept: String = "application/vnd.github+json") async throws -> String {
        let (data, _) = try await send("GET", path, accept: accept)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Endpoints

    func currentUser() async throws -> (GHUser, [String]) {
        let (data, http) = try await send("GET", "user")
        let scopes = (http.value(forHTTPHeaderField: "X-OAuth-Scopes") ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (try GitHubAPI.decoder.decode(GHUser.self, from: data), scopes)
    }

    func repo(_ owner: String, _ name: String) async throws -> GHRepo? {
        let (data, http) = try await send("GET", "repos/\(owner)/\(name)", allow: [404])
        if http.statusCode == 404 { return nil }
        return try GitHubAPI.decoder.decode(GHRepo.self, from: data)
    }

    func createRepo(owner: String, name: String, isOrg: Bool, isPrivate: Bool, description: String) async throws -> GHRepo {
        let body: [String: Any] = ["name": name, "private": isPrivate, "auto_init": true, "description": description,
                                   "has_issues": false, "has_wiki": false, "has_projects": false]
        return try await post(GHRepo.self, isOrg ? "orgs/\(owner)/repos" : "user/repos", body: body)
    }

    func ref(_ owner: String, _ repo: String, branch: String) async throws -> GHRef? {
        let (data, http) = try await send("GET", "repos/\(owner)/\(repo)/git/ref/heads/\(branch)", allow: [404, 409])
        if http.statusCode == 404 || http.statusCode == 409 { return nil }
        return try GitHubAPI.decoder.decode(GHRef.self, from: data)
    }

    func workflowRun(_ owner: String, _ repo: String, id: Int) async throws -> GHWorkflowRun {
        try await get(GHWorkflowRun.self, "repos/\(owner)/\(repo)/actions/runs/\(id)")
    }

    func runs(_ owner: String, _ repo: String, headSHA: String? = nil, perPage: Int = 30) async throws -> [GHWorkflowRun] {
        var q = ["per_page": "\(perPage)"]
        if let sha = headSHA { q["head_sha"] = sha }
        return try await get(GHRunsList.self, "repos/\(owner)/\(repo)/actions/runs", query: q).workflowRuns
    }

    func jobs(_ owner: String, _ repo: String, runId: Int) async throws -> [GHJob] {
        var all: [GHJob] = []
        var page = 1
        while true {
            let list = try await get(GHJobsList.self, "repos/\(owner)/\(repo)/actions/runs/\(runId)/jobs",
                                     query: ["per_page": "100", "page": "\(page)", "filter": "latest"])
            all.append(contentsOf: list.jobs)
            if all.count >= list.totalCount || list.jobs.isEmpty { break }
            page += 1
        }
        return all
    }

    func jobLog(_ owner: String, _ repo: String, jobId: Int) async throws -> String {
        try await text("repos/\(owner)/\(repo)/actions/jobs/\(jobId)/logs")
    }

    func annotations(_ owner: String, _ repo: String, checkRunId: Int) async throws -> [GHAnnotation] {
        try await get([GHAnnotation].self, "repos/\(owner)/\(repo)/check-runs/\(checkRunId)/annotations")
    }

    func artifacts(_ owner: String, _ repo: String, runId: Int) async throws -> [GHArtifact] {
        try await get(GHArtifactsList.self, "repos/\(owner)/\(repo)/actions/runs/\(runId)/artifacts", query: ["per_page": "100"]).artifacts
    }

    func workflows(_ owner: String, _ repo: String) async throws -> [GHWorkflow] {
        try await get(GHWorkflowsList.self, "repos/\(owner)/\(repo)/actions/workflows", query: ["per_page": "100"]).workflows
    }

    /// workflow_dispatch con return_run_details (feb 2026): restituisce l'ID della run se supportato.
    func dispatch(_ owner: String, _ repo: String, workflow: String, ref: String, inputs: [String: String]) async throws -> GHDispatchResult? {
        let body: [String: Any] = ["ref": ref, "inputs": inputs, "return_run_details": true]
        let path = "repos/\(owner)/\(repo)/actions/workflows/\(workflow)/dispatches"
        do {
            let (data, http) = try await send("POST", path, body: body)
            if http.statusCode == 204 || data.isEmpty { return nil }
            return try? GitHubAPI.decoder.decode(GHDispatchResult.self, from: data)
        } catch let e as GitHubError where e.status == 422 && e.message.contains("return_run_details") {
            // GHES / versioni che non supportano il parametro
            try await send("POST", path, body: ["ref": ref, "inputs": inputs])
            return nil
        }
    }

    func cancelRun(_ owner: String, _ repo: String, runId: Int) async throws {
        try await send("POST", "repos/\(owner)/\(repo)/actions/runs/\(runId)/cancel", allow: [409])
    }

    func rerun(_ owner: String, _ repo: String, runId: Int, failedOnly: Bool) async throws {
        try await send("POST", "repos/\(owner)/\(repo)/actions/runs/\(runId)/\(failedOnly ? "rerun-failed-jobs" : "rerun")", body: [String: Any]())
    }

    func publicKey(_ owner: String, _ repo: String) async throws -> GHPublicKey {
        try await get(GHPublicKey.self, "repos/\(owner)/\(repo)/actions/secrets/public-key")
    }

    func setSecret(_ owner: String, _ repo: String, name: String, value: String, key: GHPublicKey) async throws {
        guard let pk = Data(base64Encoded: key.key) else { throw GitHubError(status: 0, message: "Chiave pubblica non valida") }
        let sealed = try SealedBox.seal(Data(value.utf8), recipientPublicKey: pk)
        try await send("PUT", "repos/\(owner)/\(repo)/actions/secrets/\(name)",
                       body: ["encrypted_value": sealed.base64EncodedString(), "key_id": key.keyId])
    }

    func setVariable(_ owner: String, _ repo: String, name: String, value: String) async throws {
        let (_, http) = try await send("POST", "repos/\(owner)/\(repo)/actions/variables", body: ["name": name, "value": value], allow: [409, 422])
        if http.statusCode == 409 || http.statusCode == 422 {
            try await send("PATCH", "repos/\(owner)/\(repo)/actions/variables/\(name)", body: ["name": name, "value": value])
        }
    }

    func userRepos(perPage: Int = 100) async throws -> [GHRepo] {
        try await get([GHRepo].self, "user/repos", query: ["per_page": "\(perPage)", "sort": "pushed", "affiliation": "owner,collaborator,organization_member"])
    }
}

// MARK: - Modelli

struct GHUser: Decodable { let login: String; let id: Int; let name: String?; let avatarUrl: String? }

struct GHOwner: Decodable { let login: String; let type: String? }

struct GHRepo: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let fullName: String
    let `private`: Bool
    let defaultBranch: String?
    let htmlUrl: String
    let owner: GHOwner
    let size: Int?

    static func == (a: GHRepo, b: GHRepo) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct GHRefObject: Decodable { let sha: String; let type: String }
struct GHRef: Decodable { let ref: String; let object: GHRefObject }
struct GHSha: Decodable { let sha: String }
struct GHCommit: Decodable { let sha: String; let tree: GHSha; let htmlUrl: String? }

struct GHWorkflowRun: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let displayTitle: String?
    let status: String?
    let conclusion: String?
    let htmlUrl: String
    let headSha: String
    let headBranch: String?
    let event: String
    let runNumber: Int
    let runAttempt: Int?
    let createdAt: String?
    let updatedAt: String?
    let runStartedAt: String?
    let workflowId: Int
    let path: String?

    static func == (a: GHWorkflowRun, b: GHWorkflowRun) -> Bool { a.id == b.id && a.status == b.status && a.conclusion == b.conclusion }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct GHRunsList: Decodable { let totalCount: Int; let workflowRuns: [GHWorkflowRun] }

struct GHJobStep: Decodable, Hashable {
    let name: String
    let status: String
    let conclusion: String?
    let number: Int
    let startedAt: String?
    let completedAt: String?
}

struct GHJob: Decodable, Identifiable, Hashable {
    let id: Int
    let runId: Int
    let name: String
    let status: String
    let conclusion: String?
    let startedAt: String?
    let completedAt: String?
    let steps: [GHJobStep]?
    let htmlUrl: String?
    let labels: [String]?
    let runnerName: String?
}

struct GHJobsList: Decodable { let totalCount: Int; let jobs: [GHJob] }

struct GHArtifact: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let sizeInBytes: Int
    let archiveDownloadUrl: String
    let expired: Bool
    let createdAt: String?
    let expiresAt: String?
}

struct GHArtifactsList: Decodable { let totalCount: Int; let artifacts: [GHArtifact] }

struct GHAnnotation: Decodable, Hashable {
    let path: String?
    let startLine: Int?
    let endLine: Int?
    let annotationLevel: String?
    let message: String
    let title: String?
}

struct GHWorkflow: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let path: String
    let state: String
}

struct GHWorkflowsList: Decodable { let totalCount: Int; let workflows: [GHWorkflow] }

struct GHPublicKey: Decodable { let keyId: String; let key: String }

struct GHDispatchResult: Decodable { let workflowRunId: Int?; let runUrl: String?; let htmlUrl: String? }

enum ISODate {
    static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static func parse(_ s: String?) -> Date? { s.flatMap { formatter.date(from: $0) } }
}
