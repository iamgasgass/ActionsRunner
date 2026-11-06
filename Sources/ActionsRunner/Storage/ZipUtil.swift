import Foundation
import Compression

/// Lettura e scrittura di archivi ZIP senza dipendenze esterne
/// (DEFLATE grezzo tramite il framework Compression di Apple, CRC-32 implementato qui).
enum ZipUtil {
    struct ZipError: LocalizedError {
        let message: String
        var errorDescription: String? { "ZIP: \(message)" }
    }

    // MARK: CRC-32

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for b in buf { crc = crcTable[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFFFFFF
    }

    // MARK: DEFLATE

    static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + data.count / 8 + 1024
        var out = Data(count: capacity)
        let n = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0, n < data.count else { return nil }
        out.count = n
        return out
    }

    static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        if expectedSize == 0 { return Data() }
        guard !data.isEmpty else { throw ZipError(message: "dati compressi vuoti") }
        var out = Data(count: expectedSize)
        let n = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard n == expectedSize else { throw ZipError(message: "decompressione non riuscita (\(n)/\(expectedSize) byte)") }
        return out
    }

    // MARK: Lettura

    private static func u16(_ d: Data, _ o: Int) -> Int { Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 }
    private static func u32(_ d: Data, _ o: Int) -> UInt64 {
        UInt64(d[d.startIndex + o]) | UInt64(d[d.startIndex + o + 1]) << 8 | UInt64(d[d.startIndex + o + 2]) << 16 | UInt64(d[d.startIndex + o + 3]) << 24
    }
    private static func u64(_ d: Data, _ o: Int) -> UInt64 { u32(d, o) | u32(d, o + 4) << 32 }

    struct Entry {
        let name: String
        let method: Int
        let crc: UInt32
        let compressedSize: Int
        let size: Int
        let localHeaderOffset: Int
        let unixMode: UInt32
        var isDirectory: Bool { name.hasSuffix("/") || (unixMode & 0o170000) == 0o040000 }
        var isSymlink: Bool { (unixMode & 0o170000) == 0o120000 }
    }

    static func entries(of d: Data) throws -> [Entry] {
        guard d.count >= 22 else { throw ZipError(message: "file troppo piccolo") }
        // End of central directory (cerca dalla fine, commento max 64 KiB)
        var eocd = -1
        var i = d.count - 22
        let minPos = max(0, d.count - 22 - 65_535)
        while i >= minPos {
            if u32(d, i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError(message: "directory centrale non trovata (non è uno zip?)") }
        var count = u16(d, eocd + 10)
        var cdOffset = Int(u32(d, eocd + 16))
        // ZIP64
        if (count == 0xFFFF || cdOffset == 0xFFFFFFFF), eocd >= 20, u32(d, eocd - 20) == 0x07064b50 {
            let z64 = Int(u64(d, eocd - 20 + 8))
            if z64 + 56 <= d.count, u32(d, z64) == 0x06064b50 {
                count = Int(u64(d, z64 + 32))
                cdOffset = Int(u64(d, z64 + 48))
            }
        }
        var out: [Entry] = []
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= d.count, u32(d, p) == 0x02014b50 else { throw ZipError(message: "directory centrale corrotta") }
            let flags = u16(d, p + 8)
            let method = u16(d, p + 10)
            let crc = UInt32(u32(d, p + 16))
            var csize = Int(u32(d, p + 20))
            var usize = Int(u32(d, p + 24))
            let nameLen = u16(d, p + 28), extraLen = u16(d, p + 30), commentLen = u16(d, p + 32)
            let external = UInt32(u32(d, p + 38))
            var offset = Int(u32(d, p + 42))
            let nameData = d.subdata(in: (d.startIndex + p + 46)..<(d.startIndex + p + 46 + nameLen))
            let name = (flags & 0x800) != 0 ? String(decoding: nameData, as: UTF8.self)
                : (String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? "")
            // campi extra ZIP64
            var e = p + 46 + nameLen
            let eEnd = e + extraLen
            while e + 4 <= eEnd {
                let id = u16(d, e), sz = u16(d, e + 2)
                if id == 0x0001 {
                    var q = e + 4
                    if usize == 0xFFFFFFFF { usize = Int(u64(d, q)); q += 8 }
                    if csize == 0xFFFFFFFF { csize = Int(u64(d, q)); q += 8 }
                    if offset == 0xFFFFFFFF { offset = Int(u64(d, q)) }
                }
                e += 4 + sz
            }
            out.append(Entry(name: name, method: method, crc: crc, compressedSize: csize, size: usize,
                             localHeaderOffset: offset, unixMode: external >> 16))
            p += 46 + nameLen + extraLen + commentLen
        }
        return out
    }

    static func data(of entry: Entry, in d: Data) throws -> Data {
        let o = entry.localHeaderOffset
        guard o + 30 <= d.count, u32(d, o) == 0x04034b50 else { throw ZipError(message: "intestazione locale non valida per \(entry.name)") }
        let start = o + 30 + u16(d, o + 26) + u16(d, o + 28)
        guard start + entry.compressedSize <= d.count else { throw ZipError(message: "dati troncati per \(entry.name)") }
        let raw = d.subdata(in: (d.startIndex + start)..<(d.startIndex + start + entry.compressedSize))
        let result: Data
        switch entry.method {
        case 0: result = raw
        case 8: result = try inflate(raw, expectedSize: entry.size)
        default: throw ZipError(message: "metodo di compressione \(entry.method) non supportato (\(entry.name))")
        }
        if crc32(result) != entry.crc { throw ZipError(message: "CRC errato per \(entry.name)") }
        return result
    }

    /// Estrae un archivio (con protezione da path traversal, permessi Unix e symlink).
    static func unzip(_ archive: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let d = try Data(contentsOf: archive, options: .alwaysMapped)
        let base = destination.standardizedFileURL.path
        for entry in try entries(of: d) {
            let comps = entry.name.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
            guard !comps.isEmpty, !comps.contains("..") else { continue }
            let target = destination.appendingPathComponent(comps.joined(separator: "/"))
            guard target.standardizedFileURL.path.hasPrefix(base) else { continue }
            if entry.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let content = try data(of: entry, in: d)
            if fm.fileExists(atPath: target.path) || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
                try? fm.removeItem(at: target)
            }
            if entry.isSymlink {
                try fm.createSymbolicLink(atPath: target.path, withDestinationPath: String(decoding: content, as: UTF8.self))
                continue
            }
            try content.write(to: target)
            let perms = entry.unixMode & 0o777
            if perms != 0 { try? fm.setAttributes([.posixPermissions: NSNumber(value: perms)], ofItemAtPath: target.path) }
        }
    }

    // MARK: Scrittura

    private static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }

    private static func dosDateTime(_ date: Date) -> (time: Int, date: Int) {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone.current, from: date)
        let t = ((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2)
        let d = ((max((c.year ?? 1980) - 1980, 0)) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1)
        return (t, d)
    }

    /// Crea un archivio con le voci indicate (percorso relativo -> file sorgente).
    static func zip(entries input: [(relative: String, url: URL)], to destination: URL, compress: Bool = true) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else { throw ZipError(message: "impossibile scrivere \(destination.lastPathComponent)") }
        defer { try? handle.close() }
        var central = Data()
        var offset: UInt64 = 0
        var count = 0
        let (dosTime, dosDate) = dosDateTime(Date())
        for item in input {
            var rel = item.relative
            while rel.hasPrefix("/") { rel.removeFirst() }
            guard !rel.isEmpty, !rel.split(separator: "/").contains("..") else { continue }
            let attrs = try? fm.attributesOfItem(atPath: item.url.path)
            let isLink = (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink
            let perms = UInt32((attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0o644)
            let content: Data
            if isLink {
                content = Data(((try? fm.destinationOfSymbolicLink(atPath: item.url.path)) ?? "").utf8)
            } else {
                content = try Data(contentsOf: item.url, options: .alwaysMapped)
            }
            guard content.count < 0xFFFFFFFF, offset < 0xFFFFFFFF else { throw ZipError(message: "archivi oltre 4 GB non supportati") }
            let crc = crc32(content)
            var method = 0
            var payload = content
            if compress && !isLink, let deflated = deflate(content) { method = 8; payload = deflated }
            let nameBytes = Array(rel.utf8)
            var local: [UInt8] = []
            local += le32(0x04034b50) + le16(20) + le16(0x800) + le16(method) + le16(dosTime) + le16(dosDate)
            local += le32(crc) + le32(UInt32(payload.count)) + le32(UInt32(content.count))
            local += le16(nameBytes.count) + le16(0) + nameBytes
            handle.write(Data(local))
            handle.write(payload)
            let mode: UInt32 = (isLink ? 0o120000 : 0o100000) | (perms & 0o777)
            var cd: [UInt8] = []
            cd += le32(0x02014b50) + le16(0x031E) + le16(20) + le16(0x800) + le16(method) + le16(dosTime) + le16(dosDate)
            cd += le32(crc) + le32(UInt32(payload.count)) + le32(UInt32(content.count))
            cd += le16(nameBytes.count) + le16(0) + le16(0) + le16(0) + le16(0)
            cd += le32(mode << 16) + le32(UInt32(offset)) + nameBytes
            central.append(contentsOf: cd)
            offset += UInt64(local.count + payload.count)
            count += 1
        }
        guard count < 0xFFFF else { throw ZipError(message: "troppi file (oltre 65535)") }
        var end: [UInt8] = []
        end += le32(0x06054b50) + le16(0) + le16(0) + le16(count) + le16(count)
        end += le32(UInt32(central.count)) + le32(UInt32(offset)) + le16(0)
        handle.write(central)
        handle.write(Data(end))
    }

    /// Comprime una cartella intera (contenuto, senza la cartella padre).
    static func zipDirectory(_ dir: URL, to destination: URL) throws {
        try zip(entries: listFiles(in: dir), to: destination)
    }

    /// Elenco ricorsivo dei file regolari (e symlink) con percorso relativo.
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
