import CryptoKit
import Foundation

/// Pubblica il contenuto di un progetto su un branch GitHub con la Git Data API (nessun git locale).
/// Funziona con progetti di qualsiasi dimensione:
/// - calcola in locale gli SHA-1 git e invia SOLO ciò che è cambiato rispetto al branch
///   (albero costruito sopra quello attuale con `base_tree`, file rimossi con `sha: null`);
/// - costruisce l'albero a blocchi (≤ 400 voci / ~1,5 MB) concatenati con `base_tree`; se GitHub
///   va in timeout (422) il blocco viene diviso automaticamente a metà;
/// - i file di testo viaggiano dentro l'albero (`content`), quindi niente richiesta per file:
///   si evitano i limiti secondari di GitHub sulla creazione di contenuti; solo i binari diventano blob;
/// - alla fine confronta l'albero ottenuto con gli SHA-1 locali e corregge eventuali differenze;
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
        /// UTF-8 valido, senza byte nulli e non troppo grande: può viaggiare dentro l'albero.
        let isText: Bool
    }

    /// Voce dell'albero; il contenuto dei file di testo viene letto solo quando si invia il suo blocco.
    enum TreeEntry {
        case sha(path: String, mode: String, sha: String)
        case inline(path: String, mode: String, file: LocalFile)
        case delete(path: String, mode: String, type: String)

        var estimatedBytes: Int {
            switch self {
            case .sha(let p, _, _): return p.utf8.count + 80
            case .inline(let p, _, let f): return p.utf8.count + Int(f.size) + 80
            case .delete(let p, _, _): return p.utf8.count + 80
            }
        }

        func json() throws -> [String: Any] {
            switch self {
            case .sha(let p, let m, let sha):
                return ["path": p, "mode": m, "type": "blob", "sha": sha]
            case .inline(let p, let m, let f):
                let text: String
                if let t = f.symlinkTarget {
                    text = t
                } else {
                    text = String(decoding: try Data(contentsOf: f.url, options: .mappedIfSafe), as: UTF8.self)
                }
                return ["path": p, "mode": m, "type": "blob", "content": text]
            case .delete(let p, let m, let t):
                return ["path": p, "mode": m, "type": t, "sha": NSNull()]
            }
        }
    }

    static let maxBlobSize: Int64 = 100 * 1024 * 1024
    static let maxInlineSize: Int64 = 512 * 1024
    static let chunkEntries = 400
    static let chunkBytes = 1_500_000

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

    static func isInlineText(_ data: Data) -> Bool {
        guard Int64(data.count) <= maxInlineSize, !data.contains(0) else { return false }
        return String(data: data, encoding: .utf8) != nil
    }

    /// Elenco dei file del progetto con modalità git e SHA-1 (esclusa la cartella .git).
    static func scan(_ dir: URL) throws -> [LocalFile] {
        let fm = FileManager.default
        var out: [LocalFile] = []
        for f in ZipUtil.listFiles(in: dir) {
            let comps = f.relative.split(separator: "/")
            if comps.contains(".git") || comps.last == ".DS_Store" { continue }
            if let target = try? fm.destinationOfSymbolicLink(atPath: f.url.path) {
                let data = Data(target.utf8)
                out.append(LocalFile(path: f.relative, url: f.url, mode: "120000", sha: blobSHA(data),
                                     size: Int64(data.count), symlinkTarget: target, isText: true))
                continue
            }
            let attrs = try fm.attributesOfItem(atPath: f.url.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            if size > maxBlobSize {
                throw GitHubError(status: 0, message: "\(f.relative) supera 100 MB, il limite di GitHub per un singolo file (servirebbe Git LFS)")
            }
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            let data = try Data(contentsOf: f.url, options: .mappedIfSafe)
            out.append(LocalFile(path: f.relative, url: f.url, mode: (perms & 0o111) != 0 ? "100755" : "100644",
                                 sha: blobSHA(data), size: size, symlinkTarget: nil, isText: isInlineText(data)))
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
        let list = set.count > 100_000 ? Array(Array(set).suffix(100_000)) : Array(set)
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

        api.onRateLimitWait = { seconds in log("Limite di richieste di GitHub: attendo \(seconds) s e continuo…") }
        defer { api.onRateLimitWait = nil }

        // stato attuale del branch
        var head = try await headCommit(branch: branch)
        if head == nil, try await isEmptyRepository() {
            log("Repository vuoto: creo il primo commit")
            try await initializeEmptyRepository(branch: branch, with: files)
            head = try await headCommit(branch: branch)
        }

        var remote: [String: (mode: String, sha: String, type: String)]?
        var known = loadKnownBlobs()
        var currentTree: String?
        if let h = head {
            let commit: GHGitCommit = try await api.get("\(base)/git/commits/\(h)")
            currentTree = commit.tree.sha
            let tree: GHTree = try await api.get("\(base)/git/trees/\(commit.tree.sha)", query: ["recursive": "1"])
            var map: [String: (mode: String, sha: String, type: String)] = [:]
            for e in tree.tree where e.type != "tree" {
                map[e.path] = (e.mode, e.sha, e.type)
                if e.type == "blob" { known.insert(e.sha) }
            }
            if tree.truncated == true {
                log("Albero remoto molto grande (elenco troncato da GitHub): ricostruisco il branch per intero")
            } else {
                remote = map
            }
        }

        // cosa inviare
        let localPaths = Set(files.map(\.path))
        let changed: [LocalFile]
        var deletions: [String] = []
        let incremental = remote != nil && currentTree != nil
        if let remote, incremental {
            changed = files.filter { remote[$0.path]?.sha != $0.sha || remote[$0.path]?.mode != $0.mode }
            deletions = remote.keys.filter { !localPaths.contains($0) }.sorted()
        } else {
            changed = files
        }
        log(incremental
            ? "\(changed.count) file modificati o nuovi, \(deletions.count) da rimuovere"
            : "Costruzione completa dell'albero (\(files.count) file)")

        // blob solo per i binari che GitHub non ha già
        let binaries = Dictionary(grouping: changed.filter { !$0.isText && !known.contains($0.sha) }, by: \.sha).compactMap { $0.value.first }
        var uploaded = 0
        if !binaries.isEmpty {
            log("Caricamento di \(binaries.count) file binari (\(Format.bytes(binaries.reduce(Int64(0)) { $0 + $1.size })))…")
            uploaded = try await uploadBlobs(binaries, known: &known, progress: { p in progress(p * 0.5) })
        }

        // voci dell'albero: prima le rimozioni (un file può diventare cartella), poi testo inline e sha
        var entries: [TreeEntry] = deletions.map { p in
            .delete(path: p, mode: remote?[p]?.mode ?? "100644", type: remote?[p]?.type ?? "blob")
        }
        for f in changed {
            if known.contains(f.sha) || !f.isText {
                entries.append(.sha(path: f.path, mode: f.mode, sha: f.sha))
            } else {
                entries.append(.inline(path: f.path, mode: f.mode, file: f))
            }
        }

        var treeSha = currentTree ?? ""
        if !entries.isEmpty {
            treeSha = try await buildTree(entries, base: incremental ? currentTree : nil, log: log,
                                          progress: { p in progress(0.5 + p * 0.5) })
        }
        progress(1)

        // verifica: ogni file locale deve avere esattamente il suo SHA-1 nell'albero finale
        if !treeSha.isEmpty {
            treeSha = try await verifyAndRepair(treeSha: treeSha, files: files, known: &known, log: log)
        }
        for f in files { known.insert(f.sha) }
        saveKnownBlobs(known)

        if let h = head, treeSha == currentTree, !forceCommit {
            log("Contenuto identico all'ultimo commit di \(branch) (\(h.prefix(7))): nessun nuovo commit")
            return Result(commitSha: h, treeSha: treeSha, createdCommit: false, changedFiles: 0,
                          uploadedBlobs: uploaded, totalFiles: files.count)
        }
        let commit: GHSha = try await api.post("\(base)/git/commits",
                                               json: ["message": message, "tree": treeSha, "parents": head.map { [$0] } ?? [String]()],
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
        let changedCount = incremental ? changed.count + deletions.count : files.count
        log("Commit \(commit.sha.prefix(7)) su \(branch): \(changedCount) file \(incremental ? "modificati" : "inviati")")
        return Result(commitSha: commit.sha, treeSha: treeSha, createdCommit: true, changedFiles: changedCount,
                      uploadedBlobs: uploaded, totalFiles: files.count)
    }

    // MARK: Albero a blocchi

    /// Crea l'albero a blocchi concatenati con base_tree. Restituisce lo SHA dell'albero finale.
    private func buildTree(_ entries: [TreeEntry], base: String?,
                           log: (String) -> Void, progress: (Double) -> Void) async throws -> String {
        var chunks: [[TreeEntry]] = []
        var current: [TreeEntry] = []
        var bytes = 0
        for e in entries {
            let b = e.estimatedBytes
            if !current.isEmpty && (current.count >= RepoUploader.chunkEntries || bytes + b > RepoUploader.chunkBytes) {
                chunks.append(current)
                current = []
                bytes = 0
            }
            current.append(e)
            bytes += b
        }
        if !current.isEmpty { chunks.append(current) }
        if chunks.count > 1 { log("Albero in \(chunks.count) blocchi…") }

        var tree = base
        for (i, chunk) in chunks.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            let json = try chunk.map { try $0.json() }
            tree = try await createTreeChunk(json, base: tree, log: log)
            progress(Double(i + 1) / Double(chunks.count))
        }
        guard let tree else { throw GitHubError(status: 0, message: "albero vuoto") }
        return tree
    }

    /// Un blocco; se GitHub va in timeout (422) lo divide a metà e riprova.
    private func createTreeChunk(_ entries: [[String: Any]], base: String?, log: (String) -> Void) async throws -> String {
        var body: [String: Any] = ["tree": entries]
        if let base { body["base_tree"] = base }
        do {
            let t: GHSha = try await api.post("\(base_path)/git/trees", json: body, idempotent: true)
            return t.sha
        } catch let e as GitHubError where RepoUploader.isTooLarge(e) && entries.count > 1 {
            let mid = entries.count / 2
            log("Blocco troppo grande per GitHub: lo divido (\(entries.count) → \(mid) + \(entries.count - mid))")
            let first = try await createTreeChunk(Array(entries[..<mid]), base: base, log: log)
            return try await createTreeChunk(Array(entries[mid...]), base: first, log: log)
        }
    }

    private var base_path: String { base }

    static func isTooLarge(_ e: GitHubError) -> Bool {
        let m = e.message.lowercased()
        return (e.status == 422 || e.status == 502 || e.status == 504 || e.status == 413)
            && (m.contains("timed out") || m.contains("too large") || m.contains("timeout") || e.status != 422)
    }

    // MARK: Verifica finale

    /// Confronta l'albero creato con gli SHA-1 locali; i file divergenti vengono reinviati come blob.
    private func verifyAndRepair(treeSha: String, files: [LocalFile], known: inout Set<String>, log: (String) -> Void) async throws -> String {
        let tree: GHTree = try await api.get("\(base)/git/trees/\(treeSha)", query: ["recursive": "1"])
        if tree.truncated == true {
            log("Verifica saltata: albero troppo grande per essere elencato da GitHub")
            return treeSha
        }
        var remote: [String: (mode: String, sha: String)] = [:]
        for e in tree.tree where e.type == "blob" { remote[e.path] = (e.mode, e.sha) }
        let wrong = files.filter { remote[$0.path]?.sha != $0.sha || remote[$0.path]?.mode != $0.mode }
        let localPaths = Set(files.map(\.path))
        let extra = remote.keys.filter { !localPaths.contains($0) }
        if wrong.isEmpty && extra.isEmpty {
            log("Verifica completata: \(files.count) file identici al progetto")
            return treeSha
        }
        log("Correzione di \(wrong.count + extra.count) voci dopo la verifica…")
        let missing = Dictionary(grouping: wrong, by: \.sha).compactMap { $0.value.first }
        _ = try await uploadBlobs(missing, known: &known, progress: { _ in })
        var entries: [TreeEntry] = extra.map { .delete(path: $0, mode: remote[$0]?.mode ?? "100644", type: "blob") }
        entries += wrong.map { .sha(path: $0.path, mode: $0.mode, sha: $0.sha) }
        return try await buildTree(entries, base: treeSha, log: log, progress: { _ in })
    }

    // MARK: Blob (binari)

    private func uploadBlobs(_ list: [LocalFile], known: inout Set<String>, progress: @escaping (Double) -> Void) async throws -> Int {
        guard !list.isEmpty else { return 0 }
        var uploaded = 0
        let api = self.api
        let base = self.base
        var newShas: [String] = []
        try await withThrowingTaskGroup(of: String.self) { group in
            var index = 0
            while index < list.count && index < 4 {
                let f = list[index]
                index += 1
                group.addTask { try await RepoUploader.uploadBlob(f, api: api, base: base) }
            }
            while let sha = try await group.next() {
                newShas.append(sha)
                uploaded += 1
                progress(Double(uploaded) / Double(list.count))
                if index < list.count {
                    let f = list[index]
                    index += 1
                    group.addTask { try await RepoUploader.uploadBlob(f, api: api, base: base) }
                }
            }
        }
        for s in newShas { known.insert(s) }
        return uploaded
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

    // MARK: Errori e stato del repository

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
