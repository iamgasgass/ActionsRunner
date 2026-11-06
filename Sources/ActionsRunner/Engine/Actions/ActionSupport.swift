import Foundation

/// Riferimento `uses:` di uno step.
struct ActionReference {
    enum Kind { case local(String), remote(owner: String, repo: String, path: String?, ref: String), docker(String) }
    let raw: String
    let kind: Kind

    init(_ uses: String) throws {
        raw = uses
        if uses.hasPrefix("docker://") {
            kind = .docker(String(uses.dropFirst(9)))
        } else if uses.hasPrefix("./") || uses.hasPrefix("../") {
            kind = .local(uses)
        } else {
            guard let at = uses.lastIndex(of: "@") else {
                throw ExpressionError(message: "'uses: \(uses)' deve specificare una versione (@ref)")
            }
            let name = String(uses[..<at])
            let ref = String(uses[uses.index(after: at)...])
            let comps = name.split(separator: "/").map(String.init)
            guard comps.count >= 2 else { throw ExpressionError(message: "Riferimento azione non valido: \(uses)") }
            let path = comps.count > 2 ? comps[2...].joined(separator: "/") : nil
            kind = .remote(owner: comps[0], repo: comps[1], path: path, ref: ref)
        }
    }

    /// Chiave senza versione, minuscola: "actions/checkout", "actions/cache/restore".
    var key: String {
        switch kind {
        case .local(let p): return p
        case .docker(let i): return "docker://" + i
        case .remote(let o, let r, let p, _):
            return ([o, r] + (p.map { [$0] } ?? [])).joined(separator: "/").lowercased()
        }
    }

    var ref: String? {
        if case .remote(_, _, _, let r) = kind { return r }
        return nil
    }
}

/// Metadati di un'azione (action.yml).
struct ActionMetadata {
    let name: String
    let inputs: OrderedObject
    let outputs: OrderedObject
    let using: String
    let steps: [Step]
    let main: String?
    let pre: String?
    let post: String?
    let preIf: String?
    let postIf: String?
    let image: String?
    let env: JSONValue?
    let directory: URL

    var isComposite: Bool { using == "composite" }
    var isNode: Bool { using.hasPrefix("node") }
    var isDocker: Bool { using == "docker" }

    static func load(from dir: URL) throws -> ActionMetadata {
        let fm = FileManager.default
        var file = dir.appendingPathComponent("action.yml")
        if !fm.fileExists(atPath: file.path) { file = dir.appendingPathComponent("action.yaml") }
        guard fm.fileExists(atPath: file.path) else {
            throw ExpressionError(message: "action.yml non trovato in \(dir.lastPathComponent)")
        }
        let text = try String(contentsOf: file, encoding: .utf8)
        guard let root = try YAMLLoader.load(text).objectValue else { throw ExpressionError(message: "action.yml non valido") }
        let runs = root["runs"]?.objectValue ?? OrderedObject()
        let steps: [Step] = (runs["steps"]?.arrayValue ?? []).enumerated().compactMap { i, v in
            v.objectValue.map { Step(index: i, raw: $0) }
        }
        return ActionMetadata(
            name: root["name"]?.scalarString ?? dir.lastPathComponent,
            inputs: root["inputs"]?.objectValue ?? OrderedObject(),
            outputs: root["outputs"]?.objectValue ?? OrderedObject(),
            using: runs["using"]?.scalarString?.lowercased() ?? "",
            steps: steps,
            main: runs["main"]?.scalarString,
            pre: runs["pre"]?.scalarString,
            post: runs["post"]?.scalarString,
            preIf: runs["pre-if"]?.scalarString,
            postIf: runs["post-if"]?.scalarString,
            image: runs["image"]?.scalarString,
            env: runs["env"],
            directory: dir
        )
    }
}

/// Scarica le azioni remote (archivio pubblico del repository al ref indicato) con cache locale.
/// Nessun token o account: è lo stesso download anonimo che fa il runner di GitHub.
final class ActionFetcher {
    let cacheRoot: URL
    let session: URLSession

    init() {
        cacheRoot = AppPaths.actionsCache
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 600
        cfg.httpAdditionalHeaders = ["User-Agent": "ActionsRunner-iOS/2.0"]
        session = URLSession(configuration: cfg)
    }

    func directory(owner: String, repo: String, ref: String) -> URL {
        cacheRoot.appendingPathComponent("\(owner.lowercased())/\(repo.lowercased())/\(ref)", isDirectory: true)
    }

    func isCached(owner: String, repo: String, ref: String) -> Bool {
        FileManager.default.fileExists(atPath: directory(owner: owner, repo: repo, ref: ref).appendingPathComponent(".actionsrunner-complete").path)
    }

    /// Restituisce la cartella della repo dell'azione (scaricandola se necessario).
    func fetch(owner: String, repo: String, ref: String, log: (String) -> Void) async throws -> URL {
        let dir = directory(owner: owner, repo: repo, ref: ref)
        let marker = dir.appendingPathComponent(".actionsrunner-complete")
        let fm = FileManager.default
        if fm.fileExists(atPath: marker.path) {
            log("Uso la copia in cache di '\(owner)/\(repo)@\(ref)'")
            return dir
        }
        log("Download action repository '\(owner)/\(repo)@\(ref)'")
        let encodedRef = ref.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ref
        guard let url = URL(string: "https://codeload.github.com/\(owner)/\(repo)/zip/\(encodedRef)") else {
            throw ExpressionError(message: "Riferimento non valido \(owner)/\(repo)@\(ref)")
        }
        var (tmp, resp) = try await session.download(from: url)
        if let http = resp as? HTTPURLResponse, http.statusCode == 404,
           let alt = URL(string: "https://github.com/\(owner)/\(repo)/archive/\(encodedRef).zip") {
            (tmp, resp) = try await session.download(from: alt)
        }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ExpressionError(message: "Impossibile scaricare \(owner)/\(repo)@\(ref) (HTTP \(http.statusCode)). Serve una connessione Internet per le azioni non ancora in cache.")
        }
        let tmpZip = AppPaths.temp.appendingPathComponent("action-\(UUID().uuidString).zip")
        try? fm.removeItem(at: tmpZip)
        try fm.moveItem(at: tmp, to: tmpZip)
        let tmpDir = AppPaths.temp.appendingPathComponent("action-\(UUID().uuidString)")
        try ZipUtil.unzip(tmpZip, to: tmpDir)
        try? fm.removeItem(at: tmpZip)
        // L'archivio contiene una cartella radice "repo-ref/"
        let entries = try fm.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)
        let root = entries.count == 1 && FileCommands.isDir(entries[0]) ? entries[0] : tmpDir
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: root, to: dir)
        try? fm.removeItem(at: tmpDir)
        fm.createFile(atPath: marker.path, contents: Data())
        return dir
    }
}
