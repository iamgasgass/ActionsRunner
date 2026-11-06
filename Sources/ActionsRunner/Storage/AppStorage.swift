import Foundation
import Observation
import Security

enum AppPaths {
    static let fm = FileManager.default

    static var documents: URL { fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var support: URL { ensure(fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ActionsRunner", isDirectory: true)) }
    static var caches: URL { ensure(fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ActionsRunner", isDirectory: true)) }

    static var projects: URL { ensure(support.appendingPathComponent("Projects", isDirectory: true)) }
    static var cloudArtifacts: URL { ensure(caches.appendingPathComponent("GitHubArtifacts", isDirectory: true)) }
    static var exports: URL { ensure(documents.appendingPathComponent("Export", isDirectory: true)) }
    static var temp: URL { ensure(fm.temporaryDirectory.appendingPathComponent("ActionsRunner", isDirectory: true)) }

    @discardableResult
    static func ensure(_ u: URL) -> URL {
        if !fm.fileExists(atPath: u.path) { try? fm.createDirectory(at: u, withIntermediateDirectories: true) }
        return u
    }

    static func isDirectory(_ u: URL) -> Bool {
        var d: ObjCBool = false
        return fm.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue
    }

    static func size(of url: URL) -> Int64 {
        ZipUtil.listFiles(in: url).reduce(Int64(0)) { acc, f in
            acc + Int64(((try? fm.attributesOfItem(atPath: f.url.path))?[.size] as? NSNumber)?.intValue ?? 0)
        }
    }
}

// MARK: - Keychain

enum Keychain {
    static let service = "com.iamgasgass.actionsrunner"

    static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let v = value, !v.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(v.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

// MARK: - Impostazioni

/// Secrets e variabili che l'app può copiare nel repository GitHub prima dell'esecuzione.
@Observable
final class AppSettings {
    var localSecrets: [String: String] { didSet { saveSecrets() } }
    var localVariables: [String: String] { didSet { save() } }

    private static let defaultsKey = "settings.v2"

    init() {
        let d = UserDefaults.standard.dictionary(forKey: AppSettings.defaultsKey) ?? [:]
        localVariables = d["localVariables"] as? [String: String] ?? [:]
        if let s = Keychain.get("local-secrets"), let data = s.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            localSecrets = dict
        } else {
            localSecrets = [:]
        }
    }

    private func save() {
        UserDefaults.standard.set(["localVariables": localVariables], forKey: AppSettings.defaultsKey)
    }

    private func saveSecrets() {
        if let data = try? JSONSerialization.data(withJSONObject: localSecrets), let s = String(data: data, encoding: .utf8) {
            Keychain.set(s, for: "local-secrets")
        }
    }
}

// MARK: - Progetti

struct Project: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var importedAt: Date
    var sourceFileName: String
    var fileCount: Int
    var sizeBytes: Int64
    /// Repository GitHub collegato (owner/nome) e branch usati per "Esegui su GitHub".
    var githubRepo: String?
    var githubBranch: String?

    var folder: URL { AppPaths.projects.appendingPathComponent(id.uuidString, isDirectory: true) }
    var repoURL: URL { folder.appendingPathComponent("repo", isDirectory: true) }

    static func sanitizedRepoName(_ s: String) -> String {
        let allowed = s.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "-" }
        var r = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        if r.isEmpty { r = "project" }
        return String(r.prefix(90))
    }
}

@Observable
final class ProjectStore {
    var projects: [Project] = []
    var importError: String?
    var isImporting = false

    private var indexURL: URL { AppPaths.support.appendingPathComponent("projects.json") }

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        projects = ((try? dec.decode([Project].self, from: data)) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.repoURL.path) }
            .sorted { $0.importedAt > $1.importedAt }
    }

    func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(projects) { try? data.write(to: indexURL, options: .atomic) }
    }

    func update(_ p: Project) {
        if let i = projects.firstIndex(where: { $0.id == p.id }) { projects[i] = p; save() }
    }

    func project(_ id: UUID) -> Project? { projects.first { $0.id == id } }

    func delete(_ p: Project) {
        try? FileManager.default.removeItem(at: p.folder)
        projects.removeAll { $0.id == p.id }
        save()
    }

    /// Importa un file .zip (o una cartella) contenente una repository.
    func importItem(at url: URL) async -> Project? {
        isImporting = true
        importError = nil
        defer { isImporting = false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let id = UUID()
        let folder = AppPaths.projects.appendingPathComponent(id.uuidString, isDirectory: true)
        let repo = folder.appendingPathComponent("repo", isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            var baseName = url.deletingPathExtension().lastPathComponent
            if isDir.boolValue {
                try fm.copyItem(at: url, to: repo)
            } else {
                let staged = AppPaths.temp.appendingPathComponent("import-\(id.uuidString).zip")
                try? fm.removeItem(at: staged)
                try fm.copyItem(at: url, to: staged)
                let extracted = folder.appendingPathComponent("extract", isDirectory: true)
                try ZipUtil.unzip(staged, to: extracted)
                try? fm.removeItem(at: staged)
                // rimuove metadati macOS
                try? fm.removeItem(at: extracted.appendingPathComponent("__MACOSX"))
                let entries = try fm.contentsOfDirectory(atPath: extracted.path).filter { $0 != ".DS_Store" }
                // GitHub "Download ZIP" produce una cartella radice "repo-main/": la rimuoviamo
                if entries.count == 1, AppPaths.isDirectory(extracted.appendingPathComponent(entries[0])) {
                    baseName = entries[0]
                    try fm.moveItem(at: extracted.appendingPathComponent(entries[0]), to: repo)
                    try? fm.removeItem(at: extracted)
                } else {
                    try fm.moveItem(at: extracted, to: repo)
                }
            }
            // pulizia .DS_Store ricorsiva
            for f in ZipUtil.listFiles(in: repo) where f.url.lastPathComponent == ".DS_Store" { try? fm.removeItem(at: f.url) }
            let files = ZipUtil.listFiles(in: repo)
            let size = AppPaths.size(of: repo)
            var name = baseName
            for suffix in ["-main", "-master", "-develop"] where name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
            let project = Project(id: id, name: name, importedAt: Date(), sourceFileName: url.lastPathComponent,
                                  fileCount: files.count, sizeBytes: size)
            projects.insert(project, at: 0)
            save()
            return project
        } catch {
            try? fm.removeItem(at: folder)
            importError = "Importazione non riuscita: \(error.localizedDescription)"
            return nil
        }
    }

    /// Esporta la repo (eventualmente modificata) come zip.
    func export(_ p: Project) throws -> URL {
        let dest = AppPaths.exports.appendingPathComponent("\(Project.sanitizedRepoName(p.name)).zip")
        try ZipUtil.zipDirectory(p.repoURL, to: dest)
        return dest
    }
}

extension Project {
    enum CodingKeys: String, CodingKey {
        case id, name, importedAt, sourceFileName, fileCount, sizeBytes, githubRepo, githubBranch
    }

    /// Decodifica tollerante: i campi aggiunti nelle versioni successive sono facoltativi.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        importedAt = try c.decode(Date.self, forKey: .importedAt)
        sourceFileName = try c.decodeIfPresent(String.self, forKey: .sourceFileName) ?? ""
        fileCount = try c.decodeIfPresent(Int.self, forKey: .fileCount) ?? 0
        sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes) ?? 0
        githubRepo = try c.decodeIfPresent(String.self, forKey: .githubRepo)
        githubBranch = try c.decodeIfPresent(String.self, forKey: .githubBranch)
    }
}
