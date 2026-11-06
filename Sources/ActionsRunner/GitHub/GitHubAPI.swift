import Foundation

// MARK: - Errori

struct GitHubError: LocalizedError {
    let status: Int
    let message: String
    var documentation: String? = nil

    var errorDescription: String? {
        switch status {
        case 0: return message
        case 401: return "Token GitHub non valido o scaduto (401). Aggiornalo in Impostazioni → Account GitHub."
        default: return "GitHub \(status): \(message)"
        }
    }
    var isNotFound: Bool { status == 404 }
}

// MARK: - Modelli REST (solo i campi usati)

struct GHUser: Decodable, Hashable {
    let login: String
    let name: String?
}

struct GHRepo: Decodable, Identifiable, Hashable {
    struct Owner: Decodable, Hashable { let login: String }
    struct Permissions: Decodable, Hashable { let admin: Bool?; let push: Bool? }
    let id: Int
    let name: String
    let fullName: String
    let `private`: Bool
    let defaultBranch: String?
    let htmlUrl: String
    let pushedAt: String?
    let owner: Owner
    let permissions: Permissions?
    let archived: Bool?
}

struct GHWorkflow: Decodable, Hashable {
    let id: Int
    let name: String
    let path: String
    let state: String
}

struct GHWorkflowsPage: Decodable { let totalCount: Int; let workflows: [GHWorkflow] }

struct GHRun: Decodable, Hashable {
    let id: Int
    let name: String?
    let displayTitle: String?
    let status: String?
    let conclusion: String?
    let headSha: String
    let headBranch: String?
    let event: String
    let runNumber: Int
    let runAttempt: Int?
    let htmlUrl: String
    let createdAt: String
    let updatedAt: String?
    let runStartedAt: String?
    let workflowId: Int
    let path: String?

    var isCompleted: Bool { status == "completed" }
}

struct GHRunsPage: Decodable { let totalCount: Int; let workflowRuns: [GHRun] }

struct GHStep: Decodable, Hashable {
    let name: String
    let status: String
    let conclusion: String?
    let number: Int
    let startedAt: String?
    let completedAt: String?
}

struct GHJob: Decodable, Hashable {
    let id: Int
    let runId: Int
    let name: String
    let status: String
    let conclusion: String?
    let startedAt: String?
    let completedAt: String?
    let htmlUrl: String?
    let labels: [String]?
    let runnerName: String?
    let steps: [GHStep]?
    let runAttempt: Int?

    var isCompleted: Bool { status == "completed" }
}

struct GHJobsPage: Decodable { let totalCount: Int; let jobs: [GHJob] }

struct GHArtifact: Decodable, Hashable, Identifiable {
    let id: Int
    let name: String
    let sizeInBytes: Int
    let expired: Bool
    let archiveDownloadUrl: String
}

struct GHArtifactsPage: Decodable { let totalCount: Int; let artifacts: [GHArtifact] }

struct GHAnnotation: Decodable, Hashable {
    let path: String?
    let startLine: Int?
    let annotationLevel: String?
    let message: String?
    let title: String?
}

struct GHRef: Decodable {
    struct Object: Decodable { let sha: String; let type: String }
    let ref: String
    let object: Object
}

struct GHGitCommit: Decodable {
    struct TreeRef: Decodable { let sha: String }
    let sha: String
    let tree: TreeRef
}

struct GHTree: Decodable {
    struct Entry: Decodable { let path: String; let mode: String; let type: String; let sha: String }
    let sha: String
    let truncated: Bool?
    let tree: [Entry]
}

struct GHSha: Decodable { let sha: String }

struct GHPublicKey: Decodable { let keyId: String; let key: String }

// MARK: - Client

/// Client REST di GitHub senza dipendenze: URLSession, ETag (le risposte 304 non consumano il
/// rate limit), tentativi automatici sugli errori transitori, rispetto di Retry-After e dei limiti.
final class GitHubAPI: @unchecked Sendable {
    static let tokenAccount = "github-token"
    static let apiVersion = "2022-11-28"

    let token: String
    private let session: URLSession
    private let lock = NSLock()
    private var etags: [String: (etag: String, data: Data, response: HTTPURLResponse)] = [:]
    private var _rateRemaining: Int?
    private var _rateReset: Date?

    var rateRemaining: Int? { lock.lock(); defer { lock.unlock() }; return _rateRemaining }
    var rateReset: Date? { lock.lock(); defer { lock.unlock() }; return _rateReset }

    init(token: String) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 3600
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.waitsForConnectivity = true
        session = URLSession(configuration: cfg)
    }

    /// Client con il token salvato nel portachiavi (nil se non configurato).
    static var stored: GitHubAPI? {
        guard let t = Keychain.get(tokenAccount), !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return shared(for: t)
    }

    private static let cacheLock = NSLock()
    private static var cached: GitHubAPI?

    /// Riusa lo stesso client (e la sua cache ETag) finché il token non cambia.
    static func shared(for token: String) -> GitHubAPI {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let c = cached, c.token == token.trimmingCharacters(in: .whitespacesAndNewlines) { return c }
        let c = GitHubAPI(token: token)
        cached = c
        return c
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    // MARK: Richieste

    private func makeURL(_ path: String, query: [String: String]) throws -> URL {
        let full = path.hasPrefix("https://") ? path : "https://api.github.com" + (path.hasPrefix("/") ? path : "/" + path)
        guard var comps = URLComponents(string: full) else { throw GitHubError(status: 0, message: "URL non valido: \(path)") }
        if !query.isEmpty {
            var items = comps.queryItems ?? []
            for (k, v) in query.sorted(by: { $0.key < $1.key }) { items.append(URLQueryItem(name: k, value: v)) }
            comps.queryItems = items
        }
        guard let url = comps.url else { throw GitHubError(status: 0, message: "URL non valido: \(path)") }
        return url
    }

    private func baseRequest(_ url: URL, method: String, accept: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue(accept, forHTTPHeaderField: "Accept")
        r.setValue(GitHubAPI.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue("ActionsRunner-iOS", forHTTPHeaderField: "User-Agent")
        return r
    }

    private func noteRate(_ http: HTTPURLResponse) {
        lock.lock(); defer { lock.unlock() }
        if let s = http.value(forHTTPHeaderField: "X-RateLimit-Remaining"), let v = Int(s) { _rateRemaining = v }
        if let s = http.value(forHTTPHeaderField: "X-RateLimit-Reset"), let v = Double(s) { _rateReset = Date(timeIntervalSince1970: v) }
    }

    static func errorFrom(status: Int, data: Data) -> GitHubError {
        var message = HTTPURLResponse.localizedString(forStatusCode: status)
        var doc: String?
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let m = obj["message"] as? String { message = m }
            doc = obj["documentation_url"] as? String
            if let errs = obj["errors"] as? [Any], !errs.isEmpty {
                let details = errs.compactMap { e -> String? in
                    if let s = e as? String { return s }
                    if let d = e as? [String: Any] {
                        return (d["message"] as? String) ?? [d["resource"], d["field"], d["code"]].compactMap { $0 as? String }.joined(separator: " ")
                    }
                    return nil
                }
                if !details.isEmpty { message += " (" + details.joined(separator: "; ") + ")" }
            }
        } else if let s = String(data: data, encoding: .utf8), !s.isEmpty, s.count < 300 {
            message = s
        }
        return GitHubError(status: status, message: message, documentation: doc)
    }

    /// Esegue una richiesta. `idempotent` abilita i tentativi automatici sugli errori transitori.
    @discardableResult
    func send(_ method: String = "GET", _ path: String, query: [String: String] = [:], json: [String: Any]? = nil,
              accept: String = "application/vnd.github+json", useETag: Bool = true,
              idempotent: Bool? = nil) async throws -> (Data, HTTPURLResponse) {
        let url = try makeURL(path, query: query)
        var req = baseRequest(url, method: method, accept: accept)
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let key = url.absoluteString
        let etagEnabled = method == "GET" && useETag
        if etagEnabled {
            lock.lock()
            if let e = etags[key] { req.setValue(e.etag, forHTTPHeaderField: "If-None-Match") }
            lock.unlock()
        }
        let canRetry = idempotent ?? (method != "POST")
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse else { throw GitHubError(status: 0, message: "risposta non HTTP") }
                noteRate(http)
                if http.statusCode == 304, etagEnabled {
                    lock.lock()
                    let cached = etags[key]
                    lock.unlock()
                    if let cached { return (cached.data, cached.response) }
                    req.setValue(nil, forHTTPHeaderField: "If-None-Match")
                    continue
                }
                if (200..<300).contains(http.statusCode) {
                    if etagEnabled, let tag = http.value(forHTTPHeaderField: "ETag") {
                        lock.lock()
                        etags[key] = (tag, data, http)
                        if etags.count > 400 { etags.removeAll() }
                        lock.unlock()
                    }
                    return (data, http)
                }
                // limiti di frequenza: attende e riprova (anche le POST: la richiesta non è stata eseguita)
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init)
                let bodyText = String(data: data, encoding: .utf8) ?? ""
                let rateLimited = http.statusCode == 429 ||
                    (http.statusCode == 403 && (remaining == 0 || bodyText.localizedCaseInsensitiveContains("rate limit")))
                if rateLimited && attempt <= 3 {
                    var wait = retryAfter ?? 60
                    if retryAfter == nil, remaining == 0, let reset = rateReset { wait = max(5, reset.timeIntervalSinceNow + 1) }
                    if wait > 120 {
                        throw GitHubError(status: http.statusCode, message: "limite di richieste di GitHub raggiunto: riprova tra \(Int(wait / 60) + 1) minuti")
                    }
                    try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    continue
                }
                if canRetry && http.statusCode >= 500 && attempt <= 3 {
                    try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 700_000_000))
                    continue
                }
                throw GitHubAPI.errorFrom(status: http.statusCode, data: data)
            } catch let e as URLError {
                if e.code == .cancelled { throw CancellationError() }
                if canRetry && attempt <= 3 {
                    try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 700_000_000))
                    continue
                }
                throw GitHubError(status: 0, message: "rete: \(e.localizedDescription)")
            }
        }
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:], as type: T.Type = T.self) async throws -> T {
        let (data, _) = try await send("GET", path, query: query)
        return try decode(T.self, data)
    }

    func post<T: Decodable>(_ path: String, json: [String: Any], idempotent: Bool = false, as type: T.Type = T.self) async throws -> T {
        let (data, _) = try await send("POST", path, json: json, idempotent: idempotent)
        return try decode(T.self, data)
    }

    func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try GitHubAPI.decoder.decode(T.self, from: data)
        } catch {
            throw GitHubError(status: 0, message: "risposta di GitHub inattesa (\(T.self)): \(error.localizedDescription)")
        }
    }

    /// Scorre tutte le pagine (intestazione Link rel="next").
    func pages(_ path: String, query: [String: String] = [:], maxPages: Int = 20) async throws -> [Data] {
        var out: [Data] = []
        var next: String? = path
        var q = query
        if q["per_page"] == nil { q["per_page"] = "100" }
        while let p = next, out.count < maxPages {
            let (data, http) = try await send("GET", p, query: p.hasPrefix("https://") ? [:] : q)
            out.append(data)
            next = GitHubAPI.nextLink(http.value(forHTTPHeaderField: "Link"))
        }
        return out
    }

    static func nextLink(_ header: String?) -> String? {
        guard let header else { return nil }
        for part in header.components(separatedBy: ",") {
            let segs = part.components(separatedBy: ";")
            guard segs.count >= 2, segs.dropFirst().contains(where: { $0.contains("rel=\"next\"") }) else { continue }
            return segs[0].trimmingCharacters(in: CharacterSet(charactersIn: " <>"))
        }
        return nil
    }

    // MARK: Download (log, artifact): i redirect verso lo storage non devono ricevere il token

    private final class RedirectStripper: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            var r = request
            if r.url?.host != "api.github.com" { r.setValue(nil, forHTTPHeaderField: "Authorization") }
            return r
        }
    }

    /// Scarica un contenuto (seguendo il redirect) in un file temporaneo.
    func download(_ path: String) async throws -> URL {
        let url = try makeURL(path, query: [:])
        let req = baseRequest(url, method: "GET", accept: "application/vnd.github+json")
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (tmp, resp) = try await session.download(for: req, delegate: RedirectStripper())
                guard let http = resp as? HTTPURLResponse else { throw GitHubError(status: 0, message: "risposta non HTTP") }
                if (200..<300).contains(http.statusCode) {
                    let dest = AppPaths.temp.appendingPathComponent("dl-\(UUID().uuidString)")
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    return dest
                }
                let data = (try? Data(contentsOf: tmp)) ?? Data()
                if http.statusCode >= 500 && attempt <= 3 {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
                    continue
                }
                throw GitHubAPI.errorFrom(status: http.statusCode, data: data)
            } catch let e as URLError {
                if e.code == .cancelled { throw CancellationError() }
                if attempt <= 3 { try await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000); continue }
                throw GitHubError(status: 0, message: "download non riuscito: \(e.localizedDescription)")
            }
        }
    }

    func downloadText(_ path: String) async throws -> String {
        let f = try await download(path)
        defer { try? FileManager.default.removeItem(at: f) }
        let d = try Data(contentsOf: f)
        return String(decoding: d, as: UTF8.self)
    }

    // MARK: Account

    struct TokenInfo {
        let user: GHUser
        let scopes: [String]?     // nil = token fine-grained (nessuna intestazione X-OAuth-Scopes)
        let rateRemaining: Int?
    }

    func verify() async throws -> TokenInfo {
        let (data, http) = try await send("GET", "/user", useETag: false)
        let user = try decode(GHUser.self, data)
        let scopes = http.value(forHTTPHeaderField: "X-OAuth-Scopes").map {
            $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return TokenInfo(user: user, scopes: scopes, rateRemaining: rateRemaining)
    }
}

// MARK: - Percorsi

enum GHPath {
    static func repo(_ full: String) -> String { "/repos/\(full)" }
    static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))) ?? s
    }
}

// MARK: - Date di GitHub

enum GHDate {
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = plain.date(from: s) ?? fractional.date(from: s) { return d }
        // frazioni di secondo con più di 3 cifre (log): si tronca ai secondi
        if s.count >= 19, let d = plain.date(from: String(s.prefix(19)) + "Z") { return d }
        return nil
    }
}
