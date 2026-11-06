import CryptoKit
import Foundation

/// Pubblica il contenuto di un progetto su un branch GitHub con la Git Data API (nessun git locale).
/// - calcola in locale gli SHA-1 dei blob git, quindi carica SOLO i file che GitHub non ha già
///   (confronto con l'albero del branch + cache dei blob già caricati);
/// - crea un albero completo (snapshot esatto della cartella: i file rimossi spariscono anche dal branch);
/// - crea il commit con il commit precedente come genitore (la storia non viene riscritta).
final class RepoUploader: @unchecked Sendable {
    struct Result {
        let commitSha: String
        let treeSha: String
        let createdCommit: Bool
        let changedFiles: Int
        let uploadedBlobs: Int
        let totalFiles: Int
    }

    struct LocalFile {
        let path: String
        let url: URL
        let mode: String       // 100644, 100755, 120000
        let sha: String
        let size: Int64
        let symlinkTarget: String?
    }

    static let maxBlobSize: Int64 = 100 * 1024 * 1024

    let api: GitHubAPI
    let repo: String    // owner/name
    private var base: String { GHPath.repo(repo) }

    init(api: GitHubAPI, repo: String) {
        self.api = api
        self.repo = repo
    }

    // MARK: Hash git

    static func blobSHA(_ data: Data) -> String {
        var h = Insecure.SHA1()
        h.update(data: Data("blob \(data.count)\u{0}".utf8))
        h.update(data: data)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Elenco dei file del progetto con modalità git e SHA-1 (esclusa la cartella .git).
    static func scan(_ dir: URL) throws -> [LocalFile] {
        let fm = FileManager.default
        var out: [LocalFile] = []
        for f in ZipUtil.listFiles(in: dir) {
            let comps = f.relative.split(separator: "/")
            if comps.contains(".git") || f.relative == ".DS_Store" || comps.last == ".DS_Store" { continue }
            if let target = try? fm.destinationOfSymbolicLink(atPath: f.url.path) {
                let data = Data(target.utf8)
                out.append(LocalFile(path: f.relative, url: f.url, mode: "120000", sha: blobSHA(data),
                                     size: Int64(data.count), symlinkTarget: target))
                continue
            }
            let attrs = try fm.attributesOfItem(atPath: f.url.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            if size > maxBlobSize {
                throw GitHubError(status: 0, message: "\(f.relative) supera 100 MB, il limite di GitHub per un singolo file")
            }
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            let data = try Data(contentsOf: f.url, options: .mappedIfSafe)
            out.append(LocalFile(path: f.relative, url: f.url, mode: (perms & 0o111) != 0 ? "100755" : "100644",
                                 sha: blobSHA(data), size: size, symlinkTarget: nil))
        }
        return out
    }

    // MARK: Cache dei blob caricati (per repository)

    private var cacheURL: URL {
        AppPaths.support.appendingPathComponent("github-blobs-\(repo.replacingOccurrences(of: "/", with: "__")).txt")
    }

    private func loadKnownBlobs() -> Set<String> {
        guard let s = try? String(contentsOf: cacheURL, encoding: .utf8) else { return [] }
        return Set(s.split(separator: "\n").map(String.init))
    }

    private func saveKnownBlobs(_ set: Set<String>) {
        let list = set.count > 50_000 ? Array(set).suffix(50_000) : Array(set)
        try? list.joined(separator: "\n").write(to: cacheURL, atomically: true, encoding: .utf8)
    }

    // MARK: Pubblicazione

    /// - Parameters:
    ///   - forceCommit: crea un commit anche se il contenuto è identico (serve a generare un evento push).
    func push(directory: URL, branch: String, message: String, forceCommit: Bool,
              log: @escaping (String) -> Void, progress: @escaping (Double) -> Void) async throws -> Result {
        log("Analisi dei file del progetto…")
        let files = try await Task.detached(priority: .userInitiated) { try RepoUploader.scan(directory) }.value
        guard !files.isEmpty else { throw GitHubError(status: 0, message: "il progetto non contiene file") }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        log("\(files.count) file, \(Format.bytes(total))")

        // stato attuale del branch
        var head = try await headCommit(branch: branch)
        if head == nil, try await isEmptyRepository() {
            log("Repository vuoto: creo il primo commit")
            try await initializeEmptyRepository(branch: branch, with: files)
            head = try await headCommit(branch: branch)
        }

        var remote: [String: (mode: String, sha: String)] = [:]
        var known = loadKnownBlobs()
        var currentTree: String?
        if let h = head {
            let commit: GHGitCommit = try await api.get("\(base)/git/commits/\(h)")
            currentTree = commit.tree.sha
            let tree: GHTree = try await api.get("\(base)/git/trees/\(commit.tree.sha)", query: ["recursive": "1"])
            for e in tree.tree where e.type == "blob" {
                remote[e.path] = (e.mode, e.sha)
                known.insert(e.sha)
            }
        }

        let localPaths = Set(files.map(\.path))
        let changed = files.filter { remote[$0.path]?.sha != $0.sha || remote[$0.path]?.mode != $0.mode }.count
            + remote.keys.filter { !localPaths.contains($0) }.count
        let missing = Dictionary(grouping: files.filter { !known.contains($0.sha) }, by: { $0.sha }).compactMap { $0.value.first }
        if missing.isEmpty {
            log("Nessun file da caricare: tutti i contenuti sono già su GitHub")
        } else {
            let bytes = missing.reduce(Int64(0)) { $0 + $1.size }
            log("Caricamento di \(missing.count) file (\(Format.bytes(bytes)))…")
        }

        // caricamento parallelo (4 alla volta) dei blob mancanti
        var uploaded = 0
        let api = self.api
        let base = self.base
        try await withThrowingTaskGroup(of: String.self) { group in
            var index = 0
            while index < missing.count && index < 4 {
                let f = missing[index]
                index += 1
                group.addTask { try await RepoUploader.uploadBlob(f, api: api, base: base) }
            }
            while let sha = try await group.next() {
                known.insert(sha)
                uploaded += 1
                progress(Double(uploaded) / Double(max(missing.count, 1)))
                if index < missing.count {
                    let f = missing[index]
                    index += 1
                    group.addTask { try await RepoUploader.uploadBlob(f, api: api, base: base) }
                }
            }
        }
        saveKnownBlobs(known)

        // albero completo
        let entries: [[String: Any]] = files.map { ["path": $0.path, "mode": $0.mode, "type": "blob", "sha": $0.sha] }
        let tree: GHSha = try await api.post("\(base)/git/trees", json: ["tree": entries], idempotent: true)
        if let h = head, tree.sha == currentTree, !forceCommit {
            log("Contenuto identico all'ultimo commit di \(branch) (\(h.prefix(7))): nessun nuovo commit")
            return Result(commitSha: h, treeSha: tree.sha, createdCommit: false, changedFiles: 0,
                          uploadedBlobs: uploaded, totalFiles: files.count)
        }
        let commit: GHSha = try await api.post("\(base)/git/commits",
                                               json: ["message": message, "tree": tree.sha, "parents": head.map { [$0] } ?? [String]()],
                                               idempotent: true)
        do {
            if head != nil {
                try await api.send("PATCH", "\(base)/git/refs/heads/\(GHPath.escape(branch))", json: ["sha": commit.sha, "force": false])
            } else {
                try await api.send("POST", "\(base)/git/refs", json: ["ref": "refs/heads/\(branch)", "sha": commit.sha])
            }
        } catch let e as GitHubError {
            throw RepoUploader.explain(e)
        }
        log("Commit \(commit.sha.prefix(7)) su \(branch): \(changed) file modificati")
        return Result(commitSha: commit.sha, treeSha: tree.sha, createdCommit: true, changedFiles: changed,
                      uploadedBlobs: uploaded, totalFiles: files.count)
    }

    private static func uploadBlob(_ f: LocalFile, api: GitHubAPI, base: String) async throws -> String {
        let data: Data
        if let t = f.symlinkTarget { data = Data(t.utf8) } else { data = try Data(contentsOf: f.url, options: .mappedIfSafe) }
        let created: GHSha = try await api.post("\(base)/git/blobs",
                                                 json: ["content": data.base64EncodedString(), "encoding": "base64"],
                                                 idempotent: true)
        if created.sha != f.sha {
            throw GitHubError(status: 0, message: "SHA del blob diverso per \(f.path) (atteso \(f.sha), ricevuto \(created.sha))")
        }
        return created.sha
    }

    static func explain(_ e: GitHubError) -> GitHubError {
        let m = e.message.lowercased()
        if m.contains("workflow") && (e.status == 403 || e.status == 404 || e.status == 422 || m.contains("scope")) {
            return GitHubError(status: e.status, message: "il token non può modificare i file in .github/workflows: serve lo scope 'workflow' (token classic) o il permesso 'Workflows: Read and write' (token fine-grained). Dettaglio: \(e.message)")
        }
        if e.status == 404 || e.status == 403 {
            return GitHubError(status: e.status, message: "accesso in scrittura negato: il token deve avere lo scope 'repo' (classic) o 'Contents: Read and write' (fine-grained) su questo repository. Dettaglio: \(e.message)")
        }
        return e
    }

    func headCommit(branch: String) async throws -> String? {
        do {
            let ref: GHRef = try await api.get("\(base)/git/ref/heads/\(GHPath.escape(branch))")
            return ref.object.sha
        } catch let e as GitHubError where e.status == 404 || e.status == 409 {
            return nil
        }
    }

    func isEmptyRepository() async throws -> Bool {
        do {
            _ = try await api.send("GET", "\(base)/git/refs", query: ["per_page": "1"], useETag: false)
            return false
        } catch let e as GitHubError where e.status == 409 {
            return true
        } catch let e as GitHubError where e.status == 404 || e.status == 403 {
            throw GitHubError(status: e.status, message: "repository \(repo) non trovato o non accessibile con questo token (\(e.message))")
        }
    }

    /// La Git Data API non funziona su un repository senza commit: si crea il primo con la Contents API
    /// usando un file del progetto stesso (poi l'albero completo lo sostituisce).
    private func initializeEmptyRepository(branch: String, with files: [LocalFile]) async throws {
        guard let first = files.filter({ $0.symlinkTarget == nil }).min(by: { $0.size < $1.size }) else {
            throw GitHubError(status: 0, message: "nessun file regolare con cui inizializzare il repository")
        }
        let data = try Data(contentsOf: first.url)
        let path = first.path.split(separator: "/").map { GHPath.escape(String($0)) }.joined(separator: "/")
        do {
            try await api.send("PUT", "\(base)/contents/\(path)",
                               json: ["message": "Inizializzazione (ActionsRunner)", "content": data.base64EncodedString(), "branch": branch])
        } catch let e as GitHubError {
            throw RepoUploader.explain(e)
        }
    }
}
