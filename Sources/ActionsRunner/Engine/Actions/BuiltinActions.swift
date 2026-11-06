import Foundation
import CryptoKit

struct BuiltinActionContext {
    let runner: LocalWorkflowRunner
    let exec: JobExecution
    let scope: StepScope
    var model: StepRunModel
    let inputs: OrderedObject
    let ref: ActionReference
    let stepEnv: OrderedObject
    let sourceURL: URL
    let artifactsDir: URL
    let sha: String

    func input(_ name: String, _ def: String = "") -> String {
        let v = inputs.lookup(name)?.stringValue ?? ""
        return v.isEmpty ? def : v
    }

    func bool(_ name: String, _ def: Bool) -> Bool {
        let v = input(name).lowercased()
        if v.isEmpty { return def }
        return v == "true"
    }

    func log(_ s: String, _ k: LogLine.Kind = .output) { runner.emit(model, exec.commands.mask(s), k) }
    func error(_ s: String) { log("##[error]\(s)", .error) }
    func warning(_ s: String) { log("Warning: \(s)", .warning) }

    func resolve(_ path: String) -> URL {
        var p = path.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("~") { p = exec.home.path + p.dropFirst() }
        if p.hasPrefix("/") { return URL(fileURLWithPath: p).standardizedFileURL }
        return exec.workspace.appendingPathComponent(p).standardizedFileURL
    }
}

struct BuiltinResult {
    var success: Bool
    var outputs = OrderedObject()
}

enum BuiltinActions {
    /// Setup di toolchain: su iOS non c'è nulla da installare, lo step viene emulato.
    static let toolchainSetups: [String: (input: String, output: String)] = [
        "actions/setup-node": ("node-version", "node-version"),
        "actions/setup-python": ("python-version", "python-version"),
        "actions/setup-go": ("go-version", "go-version"),
        "actions/setup-java": ("java-version", "version"),
        "actions/setup-dotnet": ("dotnet-version", "dotnet-version"),
        "maxim-lobanov/setup-xcode": ("xcode-version", "version"),
        "ruby/setup-ruby": ("ruby-version", "ruby-prefix"),
        "swift-actions/setup-swift": ("swift-version", "version"),
        "subosito/flutter-action": ("flutter-version", "VERSION"),
        "gradle/actions/setup-gradle": ("gradle-version", "gradle-version"),
        "pnpm/action-setup": ("version", "dest"),
        "oven-sh/setup-bun": ("bun-version", "bun-version"),
        "denoland/setup-deno": ("deno-version", "deno-version"),
        "actions/setup-ruby": ("ruby-version", "ruby-prefix"),
        "dtolnay/rust-toolchain": ("toolchain", "name"),
        "actions-rust-lang/setup-rust-toolchain": ("toolchain", "rustc-version"),
        "android-actions/setup-android": ("packages", "ANDROID_HOME"),
        "hashicorp/setup-terraform": ("terraform_version", "terraform_version"),
        "docker/setup-buildx-action": ("version", "name"),
        "docker/setup-qemu-action": ("platforms", "platforms"),
        "actions/configure-pages": ("", "base_url")
    ]

    static let emulated: Set<String> = [
        "actions/checkout", "actions/upload-artifact", "actions/download-artifact",
        "actions/cache", "actions/cache/restore", "actions/cache/save"
    ]

    static func isEmulated(_ key: String) -> Bool {
        emulated.contains(key) || toolchainSetups[key] != nil
    }

    static func run(_ c: BuiltinActionContext) async -> BuiltinResult {
        let key = c.ref.key
        switch key {
        case "actions/checkout": return await checkout(c)
        case "actions/upload-artifact": return uploadArtifact(c)
        case "actions/download-artifact": return downloadArtifact(c)
        case "actions/cache": return cache(c, restore: true, registerSave: true)
        case "actions/cache/restore": return cache(c, restore: true, registerSave: false)
        case "actions/cache/save": return cacheSave(c, key: c.input("key"), paths: c.input("path"))
        default:
            if let spec = toolchainSetups[key] { return toolchain(c, spec) }
            c.error("Azione non emulata: \(key)")
            return BuiltinResult(success: false)
        }
    }

    // MARK: checkout

    static func checkout(_ c: BuiltinActionContext) async -> BuiltinResult {
        let selfRepo = c.exec.github["repository"]?.stringValue ?? ""
        let repository = c.input("repository", selfRepo)
        let refInput = c.input("ref")
        let pathInput = c.input("path")
        let clean = c.bool("clean", true)
        let target = pathInput.isEmpty ? c.exec.workspace : c.resolve(pathInput)
        guard target.path.hasPrefix(c.exec.workspace.deletingLastPathComponent().path) else {
            c.error("Repository path '\(target.path)' is not under '\(c.exec.workspace.path)'")
            return BuiltinResult(success: false)
        }
        c.log("Syncing repository: \(repository)")
        c.log("Getting Git version info", .groupStart)
        c.log("Working directory is '\(c.exec.workspace.path)'")
        c.log("git version 2.51.0 (emulato: copia dei file dallo zip importato)")
        c.log("", .groupEnd)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            if clean, let items = try? fm.contentsOfDirectory(atPath: target.path), !items.isEmpty {
                c.log("Deleting the contents of '\(target.path)'")
                for i in items { try? fm.removeItem(at: target.appendingPathComponent(i)) }
            }
            var source = c.sourceURL
            if repository.lowercased() != selfRepo.lowercased() {
                let comps = repository.split(separator: "/").map(String.init)
                guard comps.count == 2 else { c.error("Valore 'repository' non valido: \(repository)"); return BuiltinResult(success: false) }
                c.log("Download del repository \(repository)@\(refInput.isEmpty ? "HEAD" : refInput) tramite GitHub API (zipball)")
                let fetcher = ActionFetcher()
                source = try await fetcher.fetch(owner: comps[0], repo: comps[1], ref: refInput.isEmpty ? "HEAD" : refInput, log: { c.log($0) })
            }
            c.log("Fetching the repository", .groupStart)
            var count = 0
            for name in try fm.contentsOfDirectory(atPath: source.path) where name != ".actionsrunner-complete" {
                let dest = target.appendingPathComponent(name)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: source.appendingPathComponent(name), to: dest)
                count += 1
            }
            c.log("Copiati \(count) elementi di primo livello in \(target.path)")
            c.log("", .groupEnd)
            let ref = refInput.isEmpty ? (c.exec.github["ref"]?.stringValue ?? "") : refInput
            c.log("Checking out the ref", .groupStart)
            c.log("HEAD is now at \(c.sha.prefix(7)) Import da ActionsRunner iOS")
            c.log("", .groupEnd)
            let runner = c.runner
            let postModelName = "Post \(c.model.name)"
            c.exec.postSteps.append((name: postModelName, condition: "always()", run: { pm in
                runner.emit(pm, "Post job cleanup.", .output)
                runner.emit(pm, "Rimozione delle credenziali persistite (emulato)", .output)
                return true
            }))
            return BuiltinResult(success: true, outputs: OrderedObject([("ref", .string(ref)), ("commit", .string(c.sha))]))
        } catch {
            c.error("Checkout fallito: \(error.localizedDescription)")
            return BuiltinResult(success: false)
        }
    }

    // MARK: artifact

    static func uploadArtifact(_ c: BuiltinActionContext) -> BuiltinResult {
        let name = c.input("name", "artifact")
        let pathSpec = c.input("path")
        let ifNoFiles = c.input("if-no-files-found", "warn")
        let overwrite = c.bool("overwrite", false)
        let includeHidden = c.bool("include-hidden-files", false)
        guard !pathSpec.isEmpty else { c.error("Input required and not supplied: path"); return BuiltinResult(success: false) }
        if name.contains(where: { "\":<>|*?\r\n\\/".contains($0) }) {
            c.error("The artifact name is not valid: \(name). Contains the following character: one of \" : < > | * ? \\r \\n \\ /")
            return BuiltinResult(success: false)
        }
        let patterns = pathSpec.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let result = PathGlob.search(patterns: patterns, base: c.exec.workspace, home: c.exec.home, includeHidden: includeHidden)
        if result.files.isEmpty {
            let msg = "No files were found with the provided path: \(patterns.joined(separator: " ")). No artifacts will be uploaded."
            switch ifNoFiles {
            case "error": c.error(msg); return BuiltinResult(success: false)
            case "ignore": c.log(msg)
            default: c.warning(msg)
            }
            return BuiltinResult(success: true)
        }
        let dest = c.artifactsDir.appendingPathComponent("\(name).zip")
        if FileManager.default.fileExists(atPath: dest.path) {
            if overwrite {
                c.log("Artifact '\(name)' esistente eliminato (overwrite: true)")
            } else {
                c.error("Failed to CreateArtifact: Received non-retryable error: Failed request: (409) Conflict: an artifact with this name already exists on the workflow run")
                return BuiltinResult(success: false)
            }
        }
        c.log("With the provided path, there will be \(result.files.count) file(s) uploaded")
        c.log("Artifact name is valid!")
        c.log("Root directory input is valid!")
        do {
            let entries = result.files.map { u -> (relative: String, url: URL) in
                let rel = PathGlob.relative(u, to: result.root)
                return (relative: rel, url: u)
            }
            let compress = (Int(c.input("compression-level", "6")) ?? 6) > 0
            try ZipUtil.zip(entries: entries, to: dest, compress: compress)
            let size = ((try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber)?.int64Value ?? 0
            let digest = (try? Data(contentsOf: dest)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? ""
            c.log("Beginning upload of artifact content to blob storage")
            c.log("Uploaded bytes \(size)")
            c.log("Finished uploading artifact content to blob storage!")
            c.log("SHA256 digest of uploaded artifact zip is \(digest)")
            c.log("Artifact \(name).zip successfully finalized. Artifact ID \(abs(name.hashValue % 1_000_000))")
            c.log("Artifact salvato localmente: \(dest.lastPathComponent) — visibile nella sezione Artifact della run", .notice)
            return BuiltinResult(success: true, outputs: OrderedObject([
                ("artifact-id", .string(String(abs(name.hashValue % 1_000_000)))),
                ("artifact-url", .string(dest.path)),
                ("artifact-digest", .string(digest))
            ]))
        } catch {
            c.error("Upload fallito: \(error.localizedDescription)")
            return BuiltinResult(success: false)
        }
    }

    static func downloadArtifact(_ c: BuiltinActionContext) -> BuiltinResult {
        let name = c.input("name")
        let pattern = c.input("pattern")
        let merge = c.bool("merge-multiple", false)
        let path = c.input("path")
        let dest = path.isEmpty ? c.exec.workspace : c.resolve(path)
        let fm = FileManager.default
        let all = ((try? fm.contentsOfDirectory(at: c.artifactsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "zip" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var selected: [URL] = []
        if !name.isEmpty {
            guard let u = all.first(where: { $0.deletingPathExtension().lastPathComponent == name }) else {
                c.error("Unable to download artifact(s): Artifact not found for name: \(name)")
                return BuiltinResult(success: false)
            }
            selected = [u]
        } else {
            selected = all.filter { pattern.isEmpty || ShellPattern.matches($0.deletingPathExtension().lastPathComponent, pattern) }
        }
        c.log("Downloading \(selected.count) artifact(s) to \(dest.path)")
        do {
            for u in selected {
                let artifactName = u.deletingPathExtension().lastPathComponent
                let target = (!name.isEmpty || merge) ? dest : dest.appendingPathComponent(artifactName)
                let tmp = c.exec.temp.appendingPathComponent("dl-\(UUID().uuidString)")
                try ZipUtil.unzip(u, to: tmp)
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                for item in try fm.contentsOfDirectory(atPath: tmp.path) {
                    try FileCommands.copyItem(tmp.appendingPathComponent(item), to: target.appendingPathComponent(item), move: true, noClobber: false)
                }
                try? fm.removeItem(at: tmp)
                c.log("Artifact '\(artifactName)' estratto in \(target.path)")
            }
            c.log("Total of \(selected.count) artifact(s) downloaded")
            return BuiltinResult(success: true, outputs: OrderedObject([("download-path", .string(dest.path))]))
        } catch {
            c.error("Download fallito: \(error.localizedDescription)")
            return BuiltinResult(success: false)
        }
    }

    // MARK: cache

    struct CacheManifest: Codable {
        var key: String
        var entries: [String]   // ws:<rel> | home:<rel> | abs:<path>
        var created: Date
    }

    static func cacheDir(for key: String) -> URL {
        let safe = String(key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" }.prefix(80))
        let h = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        return AppPaths.cacheStore.appendingPathComponent("\(safe)-\(h)", isDirectory: true)
    }

    static func allCaches() -> [(URL, CacheManifest)] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: AppPaths.cacheStore, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { d in
            guard let data = try? Data(contentsOf: d.appendingPathComponent("manifest.json")),
                  let m = try? JSONDecoder().decode(CacheManifest.self, from: data) else { return nil }
            return (d, m)
        }
    }

    static func cachePaths(_ spec: String, _ c: BuiltinActionContext) -> [(token: String, url: URL)] {
        spec.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("!") }.map { p in
            let u = c.resolve(p)
            let ws = c.exec.workspace.path, home = c.exec.home.path
            if u.path.hasPrefix(ws + "/") { return ("ws:" + String(u.path.dropFirst(ws.count + 1)), u) }
            if u.path == ws { return ("ws:.", u) }
            if u.path.hasPrefix(home + "/") { return ("home:" + String(u.path.dropFirst(home.count + 1)), u) }
            return ("abs:" + u.path, u)
        }
    }

    static func cache(_ c: BuiltinActionContext, restore: Bool, registerSave: Bool) -> BuiltinResult {
        let key = c.input("key")
        let paths = c.input("path")
        guard !key.isEmpty else { c.error("Input required and not supplied: key"); return BuiltinResult(success: false) }
        guard !paths.isEmpty else { c.error("Input required and not supplied: path"); return BuiltinResult(success: false) }
        let restoreKeys = c.input("restore-keys").components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let lookupOnly = c.bool("lookup-only", false)
        let failOnMiss = c.bool("fail-on-cache-miss", false)

        var matched: (URL, CacheManifest)? = nil
        let caches = allCaches()
        if let exact = caches.first(where: { $0.1.key == key }) { matched = exact }
        else {
            for rk in restoreKeys {
                let candidates = caches.filter { $0.1.key.hasPrefix(rk) }.sorted { $0.1.created > $1.1.created }
                if let best = candidates.first { matched = best; break }
            }
        }
        var outputs = OrderedObject([("cache-primary-key", .string(key))])
        let exactHit = matched?.1.key == key
        if let m = matched {
            let dir = m.0
            let manifest = m.1
            c.log("Cache restored from key: \(manifest.key)")
            outputs["cache-matched-key"] = .string(manifest.key)
            if !lookupOnly {
                restoreCache(dir: dir, manifest: manifest, c)
            }
        } else {
            c.log("Cache not found for input keys: \(([key] + restoreKeys).joined(separator: ", "))")
            if failOnMiss {
                c.error("Failed to restore cache entry. Exiting as fail-on-cache-miss is set. Input key: \(key)")
                return BuiltinResult(success: false)
            }
        }
        outputs["cache-hit"] = .string(exactHit ? "true" : "false")
        if registerSave {
            let postName = "Post \(c.model.name)"
            c.exec.postSteps.append((name: postName, condition: "success()", run: { pm in
                var pc = c
                pc.model = pm
                if exactHit {
                    pc.log("Cache hit occurred on the primary key \(key), not saving cache.")
                    return true
                }
                return cacheSave(pc, key: key, paths: paths).success
            }))
        }
        return BuiltinResult(success: true, outputs: outputs)
    }

    static func restoreCache(dir: URL, manifest: CacheManifest, _ c: BuiltinActionContext) {
        let fm = FileManager.default
        for (i, token) in manifest.entries.enumerated() {
            let src = dir.appendingPathComponent("\(i)")
            let dest: URL
            if token.hasPrefix("ws:") { dest = c.exec.workspace.appendingPathComponent(String(token.dropFirst(3))) }
            else if token.hasPrefix("home:") { dest = c.exec.home.appendingPathComponent(String(token.dropFirst(5))) }
            else { dest = URL(fileURLWithPath: String(token.dropFirst(4))) }
            guard fm.fileExists(atPath: src.path) else { continue }
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileCommands.copyItem(src, to: dest, move: false, noClobber: false)
        }
        c.log("Cache ripristinata (\(manifest.entries.count) percorsi)")
    }

    static func cacheSave(_ c: BuiltinActionContext, key: String, paths: String) -> BuiltinResult {
        guard !key.isEmpty else { c.error("Input required and not supplied: key"); return BuiltinResult(success: false) }
        let fm = FileManager.default
        let dir = cacheDir(for: key)
        if fm.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) {
            c.warning("Failed to save: Unable to reserve cache with key \(key), another job may be creating this cache.")
            return BuiltinResult(success: true)
        }
        let entries = cachePaths(paths, c)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var tokens: [String] = []
        for (i, e) in entries.enumerated() {
            tokens.append(e.token)
            guard fm.fileExists(atPath: e.url.path) else { continue }
            try? fm.copyItem(at: e.url, to: dir.appendingPathComponent("\(i)"))
        }
        if entries.allSatisfy({ !fm.fileExists(atPath: $0.url.path) }) {
            c.warning("Path Validation Error: Path(s) specified in the action for caching do(es) not exist, hence no cache is being saved.")
            try? fm.removeItem(at: dir)
            return BuiltinResult(success: true)
        }
        let manifest = CacheManifest(key: key, entries: tokens, created: Date())
        if let data = try? JSONEncoder().encode(manifest) { try? data.write(to: dir.appendingPathComponent("manifest.json")) }
        c.log("Cache saved with key: \(key)")
        return BuiltinResult(success: true)
    }

    // MARK: toolchain

    static func toolchain(_ c: BuiltinActionContext, _ spec: (input: String, output: String)) -> BuiltinResult {
        let version = spec.input.isEmpty ? "" : c.input(spec.input)
        if LinuxVM.shared.isSupported {
            c.log("'\(c.ref.raw)': uso la toolchain preinstallata nella VM Linux (Alpine riscv64) al posto del download (\(version.isEmpty ? "versione predefinita" : "richiesta: " + version)).", .notice)
        } else {
            c.warning("'\(c.ref.raw)' emulato: nessuna toolchain installabile (\(version.isEmpty ? "versione predefinita" : version)).")
        }
        onMain { c.model.note = "Emulato" }
        var out = OrderedObject()
        out[spec.output] = .string(version.isEmpty ? "emulated" : version)
        if c.ref.key == "actions/setup-node" || c.ref.key == "actions/setup-python" { out["cache-hit"] = .string("false") }
        if c.ref.key == "actions/setup-python" { out["python-path"] = .string("/usr/bin/python3") }
        return BuiltinResult(success: true, outputs: out)
    }
}

/// Glob in stile @actions/glob: `*` (non attraversa '/'), `**` (ricorsivo), `?`, `[...]`, `!` = esclusione.
enum PathGlob {
    static func hasGlob(_ s: String) -> Bool { s.contains(where: { "*?[".contains($0) }) }

    static func regex(_ pattern: String) -> NSRegularExpression? {
        var re = "^"
        let c = Array(pattern)
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "*" {
                if i + 1 < c.count, c[i + 1] == "*" {
                    if i + 2 < c.count, c[i + 2] == "/" { re += "(?:.*/)?"; i += 3; continue }
                    re += ".*"; i += 2; continue
                }
                re += "[^/]*"
            } else if ch == "?" {
                re += "[^/]"
            } else if ch == "[" , let close = c[(i + 1)...].firstIndex(of: "]") {
                var cls = String(c[(i + 1)..<close])
                if cls.hasPrefix("!") { cls = "^" + cls.dropFirst() }
                re += "[" + cls + "]"
                i = close + 1
                continue
            } else {
                re += NSRegularExpression.escapedPattern(for: String(ch))
            }
            i += 1
        }
        re += "(?:/.*)?$"   // un pattern che corrisponde a una cartella include il suo contenuto
        return try? NSRegularExpression(pattern: re)
    }

    static func relative(_ u: URL, to root: URL) -> String {
        let p = u.standardizedFileURL.path, r = root.standardizedFileURL.path
        if p.hasPrefix(r + "/") { return String(p.dropFirst(r.count + 1)) }
        return u.lastPathComponent
    }

    /// Prefisso senza caratteri glob di un pattern assoluto.
    static func searchRoot(_ absolutePattern: String) -> String {
        var comps: [String] = []
        for comp in absolutePattern.split(separator: "/", omittingEmptySubsequences: true) {
            if hasGlob(String(comp)) { break }
            comps.append(String(comp))
        }
        return "/" + comps.joined(separator: "/")
    }

    struct SearchResult {
        var files: [URL]
        var root: URL
    }

    static func search(patterns: [String], base: URL, home: URL, includeHidden: Bool) -> SearchResult {
        let fm = FileManager.default
        func absolute(_ p: String) -> String {
            var s = p
            if s.hasPrefix("~") { s = home.path + s.dropFirst() }
            if !s.hasPrefix("/") { s = base.appendingPathComponent(s).standardizedFileURL.path }
            while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
            return s
        }
        var includes: [String] = []
        var excludes: [NSRegularExpression] = []
        for p in patterns {
            if p.hasPrefix("!") { if let r = regex(absolute(String(p.dropFirst()))) { excludes.append(r) } }
            else { includes.append(absolute(p)) }
        }
        var found: [String: URL] = [:]
        var roots: [String] = []
        for inc in includes {
            if !hasGlob(inc) {
                let u = URL(fileURLWithPath: inc)
                if FileCommands.isDir(u) {
                    roots.append(inc)
                    for f in ZipUtil.listFiles(in: u) { found[f.url.standardizedFileURL.path] = f.url }
                } else if fm.fileExists(atPath: inc) {
                    roots.append(u.deletingLastPathComponent().path)
                    found[inc] = u
                }
                continue
            }
            let root = searchRoot(inc)
            roots.append(root)
            guard let r = regex(inc) else { continue }
            for f in ZipUtil.listFiles(in: URL(fileURLWithPath: root)) {
                let p = f.url.standardizedFileURL.path
                if r.firstMatch(in: p, range: NSRange(p.startIndex..., in: p)) != nil { found[p] = f.url }
            }
        }
        // radice = antenato comune minimo dei percorsi di ricerca
        var rootComps = roots.first.map { $0.split(separator: "/").map(String.init) } ?? base.path.split(separator: "/").map(String.init)
        for r in roots.dropFirst() {
            let comps = r.split(separator: "/").map(String.init)
            var n = 0
            while n < rootComps.count, n < comps.count, rootComps[n] == comps[n] { n += 1 }
            rootComps = Array(rootComps.prefix(n))
        }
        let root = URL(fileURLWithPath: "/" + rootComps.joined(separator: "/"))
        var files = found.filter { pair in
            !excludes.contains { $0.firstMatch(in: pair.key, range: NSRange(pair.key.startIndex..., in: pair.key)) != nil }
        }.map { $0.value }
        if !includeHidden {
            files = files.filter { !relative($0, to: root).split(separator: "/").contains { $0.hasPrefix(".") } }
        }
        files.sort { $0.path < $1.path }
        return SearchResult(files: files, root: root)
    }

    /// hashFiles(): SHA-256 della concatenazione degli SHA-256 dei file (ordinati), '' se nessun file.
    static func hashFiles(_ patterns: [String], root: URL) -> String {
        let lines = patterns.flatMap { $0.components(separatedBy: "\n") }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let result = search(patterns: lines, base: root, home: root, includeHidden: true)
        let files = result.files.filter { $0.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") }
        guard !files.isEmpty else { return "" }
        var combined = SHA256()
        for f in files {
            guard let data = try? Data(contentsOf: f) else { continue }
            combined.update(data: Data(SHA256.hash(data: data)))
        }
        return combined.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
