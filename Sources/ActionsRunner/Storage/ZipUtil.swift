import Foundation
import ZIPFoundation

enum ZipUtil {
    struct ZipError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Crea un archivio con le voci indicate (percorso relativo -> file sorgente).
    /// I file vengono disposti in una cartella di staging e compressi con FileManager.zipItem.
    static func zip(entries: [(relative: String, url: URL)], to destination: URL, compress: Bool = true) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = fm.temporaryDirectory.appendingPathComponent("zip-staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for entry in entries {
            let rel = entry.relative.hasPrefix("/") ? String(entry.relative.dropFirst()) : entry.relative
            guard !rel.isEmpty, !rel.split(separator: "/").contains("..") else { continue }
            let target = staging.appendingPathComponent(rel)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: entry.url, to: target)
        }
        try fm.zipItem(at: staging, to: destination, shouldKeepParent: false,
                       compressionMethod: compress ? .deflate : .none)
    }

    /// Comprime una cartella intera (contenuto, senza la cartella padre).
    static func zipDirectory(_ dir: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.zipItem(at: dir, to: destination, shouldKeepParent: false, compressionMethod: .deflate)
    }

    static func unzip(_ archive: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try fm.unzipItem(at: archive, to: destination)
    }

    /// Elenco ricorsivo dei file regolari con percorso relativo.
    static func listFiles(in dir: URL, includeHidden: Bool = true) -> [(relative: String, url: URL)] {
        let fm = FileManager.default
        let basePath = dir.standardizedFileURL.path
        let resolvedBase = dir.standardizedFileURL.resolvingSymlinksInPath().path
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                                    options: includeHidden ? [] : [.skipsHiddenFiles]) else { return [] }
        var out: [(relative: String, url: URL)] = []
        for case let url as URL in e {
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard vals?.isRegularFile == true || vals?.isSymbolicLink == true else { continue }
            let p = url.standardizedFileURL.path
            var rel: String
            if p.hasPrefix(basePath + "/") {
                rel = String(p.dropFirst(basePath.count + 1))
            } else {
                let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
                let full = parent + "/" + url.lastPathComponent
                rel = full.hasPrefix(resolvedBase + "/") ? String(full.dropFirst(resolvedBase.count + 1)) : url.lastPathComponent
            }
            if rel.hasPrefix("/") { rel.removeFirst() }
            out.append((relative: rel, url: url))
        }
        return out.sorted { $0.relative < $1.relative }
    }
}
