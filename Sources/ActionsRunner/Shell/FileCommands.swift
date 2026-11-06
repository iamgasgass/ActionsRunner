import Foundation

/// Opzioni brevi combinate (-rf) + operandi.
struct ParsedArgs {
    var flags = Set<Character>()
    var longFlags = Set<String>()
    var operands: [String] = []

    init(_ args: [String], valueFlags: Set<Character> = [], values: inout [Character: String]) {
        var i = 0
        var endOfOptions = false
        while i < args.count {
            let a = args[i]
            if endOfOptions || !a.hasPrefix("-") || a == "-" {
                operands.append(a); i += 1; continue
            }
            if a == "--" { endOfOptions = true; i += 1; continue }
            if a.hasPrefix("--") { longFlags.insert(String(a.dropFirst(2))); i += 1; continue }
            let chars = Array(a.dropFirst())
            var j = 0
            while j < chars.count {
                let f = chars[j]
                if valueFlags.contains(f) {
                    let rest = String(chars[(j + 1)...])
                    if !rest.isEmpty { values[f] = rest }
                    else if i + 1 < args.count { values[f] = args[i + 1]; i += 1 }
                    break
                }
                flags.insert(f)
                j += 1
            }
            i += 1
        }
    }

    init(_ args: [String]) {
        var v: [Character: String] = [:]
        self.init(args, values: &v)
    }
}

enum FileCommands {
    static let fm = FileManager.default

    static func isDir(_ u: URL) -> Bool {
        var d: ObjCBool = false
        return fm.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue
    }

    static func exists(_ u: URL) -> Bool {
        fm.fileExists(atPath: u.path) || (try? fm.destinationOfSymbolicLink(atPath: u.path)) != nil
    }

    static func ls(_ args: [String], _ io: ShIO, _ sh: ShellInterpreter) -> Int32 {
        let p = ParsedArgs(args)
        let all = p.flags.contains("a") || p.flags.contains("A")
        let long = p.flags.contains("l")
        let recursive = p.flags.contains("R")
        let targets = p.operands.isEmpty ? ["."] : p.operands
        var st: Int32 = 0
        func list(_ u: URL, label: String, header: Bool) {
            if !isDir(u) {
                io.stdout.write((long ? longLine(u, name: label) : label) + "\n")
                return
            }
            if header { io.stdout.write("\(label):\n") }
            var names = ((try? fm.contentsOfDirectory(atPath: u.path)) ?? []).sorted()
            if !all { names = names.filter { !$0.hasPrefix(".") } }
            if p.flags.contains("a") { names = [".", ".."] + names }
            if long { io.stdout.write("total \(names.count * 8)\n") }
            for n in names { io.stdout.write((long ? longLine(u.appendingPathComponent(n), name: n) : n) + "\n") }
            if recursive {
                for n in names where n != "." && n != ".." && isDir(u.appendingPathComponent(n)) {
                    io.stdout.write("\n")
                    list(u.appendingPathComponent(n), label: label == "." ? "./\(n)" : "\(label)/\(n)", header: true)
                }
            }
        }
        for t in targets {
            let u = sh.resolve(t)
            guard exists(u) else {
                io.stderr.write("ls: impossibile accedere a '\(t)': File o directory non esistente\n")
                st = 2
                continue
            }
            list(u, label: t, header: targets.count > 1 || recursive)
        }
        return st
    }

    static func longLine(_ u: URL, name: String) -> String {
        let attrs = (try? fm.attributesOfItem(atPath: u.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        let date = (attrs[.modificationDate] as? Date) ?? Date()
        let type = attrs[.type] as? FileAttributeType
        var s = type == .typeDirectory ? "d" : (type == .typeSymbolicLink ? "l" : "-")
        let bits: [(Int, Character)] = [(0o400, "r"), (0o200, "w"), (0o100, "x"), (0o40, "r"), (0o20, "w"), (0o10, "x"), (0o4, "r"), (0o2, "w"), (0o1, "x")]
        for (b, c) in bits { s.append(perms & b != 0 ? c : "-") }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "MMM dd HH:mm"
        return "\(s) 1 runner docker \(String(format: "%8d", size)) \(df.string(from: date)) \(name)"
    }

    static func mkdir(_ args: [String], _ io: ShIO, _ sh: ShellInterpreter) -> Int32 {
        var values: [Character: String] = [:]
        let p = ParsedArgs(args, valueFlags: ["m"], values: &values)
        let parents = p.flags.contains("p") || p.longFlags.contains("parents")
        for d in p.operands {
            let u = sh.resolve(d)
            if isDir(u) {
                if parents { continue }
                io.stderr.write("mkdir: impossibile creare la directory '\(d)': Il file esiste\n")
                return 1
            }
            if !parents && !isDir(u.deletingLastPathComponent()) {
                io.stderr.write("mkdir: impossibile creare la directory '\(d)': File o directory non esistente\n")
                return 1
            }
            do { try fm.createDirectory(at: u, withIntermediateDirectories: parents) } catch {
                io.stderr.write("mkdir: \(d): \(error.localizedDescription)\n")
                return 1
            }
        }
        return 0
    }

    static func rm(_ args: [String], _ io: ShIO, _ sh: ShellInterpreter) -> Int32 {
        let p = ParsedArgs(args)
        let force = p.flags.contains("f")
        let recursive = p.flags.contains("r") || p.flags.contains("R") || p.longFlags.contains("recursive")
        var st: Int32 = 0
        for f in p.operands {
            let u = sh.resolve(f)
            guard exists(u) else {
                if !force { io.stderr.write("rm: impossibile rimuovere '\(f)': File o directory non esistente\n"); st = 1 }
                continue
            }
            if isDir(u) && !recursive && !p.flags.contains("d") {
                io.stderr.write("rm: impossibile rimuovere '\(f)': È una directory\n"); st = 1; continue
            }
            do { try fm.removeItem(at: u) } catch {
                io.stderr.write("rm: \(f): \(error.localizedDescription)\n"); st = 1
            }
        }
        return st
    }

    static func cp(_ args: [String], _ io: ShIO, _ sh: ShellInterpreter, move: Bool) -> Int32 {
        let p = ParsedArgs(args)
        let recursive = move || p.flags.contains("r") || p.flags.contains("R") || p.flags.contains("a") || p.longFlags.contains("recursive")
        let noClobber = p.flags.contains("n")
        let cmd = move ? "mv" : "cp"
        guard p.operands.count >= 2 else { io.stderr.write("\(cmd): operando file mancante\n"); return 1 }
        let sources = p.operands.dropLast()
        let dest = sh.resolve(p.operands.last!)
        let destIsDir = isDir(dest)
        if sources.count > 1 && !destIsDir {
            io.stderr.write("\(cmd): la destinazione '\(p.operands.last!)' non è una directory\n"); return 1
        }
        var st: Int32 = 0
        for s in sources {
            // cp -r dir/. dest  => copia il contenuto
            let copyContents = s.hasSuffix("/.")
            let src = sh.resolve(copyContents ? String(s.dropLast(2)) : s)
            guard exists(src) else { io.stderr.write("\(cmd): impossibile fare stat di '\(s)': File o directory non esistente\n"); st = 1; continue }
            if isDir(src) && !recursive { io.stderr.write("\(cmd): -r non specificato; directory '\(s)' omessa\n"); st = 1; continue }
            do {
                if copyContents {
                    try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                    for n in try fm.contentsOfDirectory(atPath: src.path) {
                        try copyItem(src.appendingPathComponent(n), to: dest.appendingPathComponent(n), move: move, noClobber: noClobber)
                    }
                    continue
                }
                let target = destIsDir ? dest.appendingPathComponent(src.lastPathComponent) : dest
                try copyItem(src, to: target, move: move, noClobber: noClobber)
            } catch {
                io.stderr.write("\(cmd): \(s): \(error.localizedDescription)\n"); st = 1
            }
        }
        return st
    }

    static func copyItem(_ src: URL, to target: URL, move: Bool, noClobber: Bool) throws {
        if exists(target) {
            if noClobber { return }
            if isDir(target) && isDir(src) && !move {
                // merge ricorsivo
                for n in try fm.contentsOfDirectory(atPath: src.path) {
                    try copyItem(src.appendingPathComponent(n), to: target.appendingPathComponent(n), move: false, noClobber: false)
                }
                return
            }
            try fm.removeItem(at: target)
        }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if move { try fm.moveItem(at: src, to: target) } else { try fm.copyItem(at: src, to: target) }
    }

    static func ln(_ args: [String], _ io: ShIO, _ sh: ShellInterpreter) -> Int32 {
        let p = ParsedArgs(args)
        guard p.operands.count >= 2 else { io.stderr.write("ln: operando mancante\n"); return 1 }
        let target = p.operands[0]
        var link = sh.resolve(p.operands[1])
        if isDir(link) && !p.flags.contains("n") { link = link.appendingPathComponent((target as NSString).lastPathComponent) }
        if p.flags.contains("f") { try? fm.removeItem(at: link) }
        do {
            if p.flags.contains("s") {
                try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
            } else {
                try fm.linkItem(at: sh.resolve(target), to: link)
            }
        } catch {
            io.stderr.write("ln: \(error.localizedDescription)\n"); return 1
        }
        return 0
    }

    static func chmod(_ args: [String], _ io: ShIO, _ sh: ShellInterpreter) -> Int32 {
        var rest = args.filter { $0 != "-R" && $0 != "-v" && $0 != "-f" }
        guard rest.count >= 2 else { io.stderr.write("chmod: operando mancante\n"); return 1 }
        let mode = rest.removeFirst()
        for f in rest {
            let u = sh.resolve(f)
            let cur = ((try? fm.attributesOfItem(atPath: u.path))?[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            var newMode = cur
            if let octal = Int(mode, radix: 8) {
                newMode = octal
            } else {
                for clause in mode.split(separator: ",") {
                    let s = String(clause)
                    guard let opIdx = s.firstIndex(where: { "+-=".contains($0) }) else { continue }
                    var who = String(s[..<opIdx])
                    if who.isEmpty || who.contains("a") { who = "ugo" }
                    let op = s[opIdx]
                    let perms = s[s.index(after: opIdx)...]
                    var mask = 0
                    for w in who {
                        let shift = w == "u" ? 6 : (w == "g" ? 3 : 0)
                        for pch in perms {
                            let bit = pch == "r" ? 4 : (pch == "w" ? 2 : (pch == "x" ? 1 : 0))
                            mask |= bit << shift
                        }
                    }
                    switch op {
                    case "+": newMode |= mask
                    case "-": newMode &= ~mask
                    default: newMode = mask
                    }
                }
            }
            do { try fm.setAttributes([.posixPermissions: NSNumber(value: newMode)], ofItemAtPath: u.path) } catch {
                io.stderr.write("chmod: impossibile accedere a '\(f)': \(error.localizedDescription)\n"); return 1
            }
        }
        return 0
    }

    static func stat(_ args: [String], _ io: ShIO, _ sh: ShellInterpreter) -> Int32 {
        var values: [Character: String] = [:]
        let p = ParsedArgs(args, valueFlags: ["c", "f"], values: &values)
        for f in p.operands {
            let u = sh.resolve(f)
            guard let attrs = try? fm.attributesOfItem(atPath: u.path) else {
                io.stderr.write("stat: impossibile fare stat di '\(f)'\n"); return 1
            }
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            if let fmt = values["c"] ?? values["f"] {
                var out = fmt.replacingOccurrences(of: "%s", with: "\(size)").replacingOccurrences(of: "%z", with: "\(size)")
                out = out.replacingOccurrences(of: "%n", with: f).replacingOccurrences(of: "%N", with: f)
                let mtime = Int((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
                out = out.replacingOccurrences(of: "%Y", with: "\(mtime)").replacingOccurrences(of: "%m", with: "\(mtime)")
                io.stdout.write(out + "\n")
            } else {
                io.stdout.write("  File: \(f)\n  Size: \(size)\n")
            }
        }
        return 0
    }

    static func du(_ args: [String], _ io: ShIO, _ sh: ShellInterpreter) -> Int32 {
        let p = ParsedArgs(args)
        let human = p.flags.contains("h")
        for f in (p.operands.isEmpty ? ["."] : p.operands) {
            let u = sh.resolve(f)
            var total = 0
            if isDir(u) {
                for e in ZipUtil.listFiles(in: u) {
                    total += ((try? fm.attributesOfItem(atPath: e.url.path))?[.size] as? NSNumber)?.intValue ?? 0
                }
            } else {
                total = ((try? fm.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.intValue ?? 0
            }
            let s = human ? ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file) : "\(max(1, total / 1024))"
            io.stdout.write("\(s)\t\(f)\n")
        }
        return 0
    }

    /// Restituisce lo stato e, se presente -exec, lo script da eseguire.
    static func find(_ args: [String], _ io: ShIO, _ sh: ShellInterpreter) -> (Int32, String?) {
        var paths: [String] = []
        var i = 0
        while i < args.count, !args[i].hasPrefix("-"), args[i] != "!", args[i] != "(" { paths.append(args[i]); i += 1 }
        if paths.isEmpty { paths = ["."] }
        var namePatterns: [(String, Bool, Bool)] = []  // pattern, caseInsensitive, negated
        var pathPatterns: [String] = []
        var type: Character? = nil
        var maxDepth = Int.max
        var minDepth = 0
        var delete = false
        var negateNext = false
        var execCmd: [String]? = nil
        while i < args.count {
            let a = args[i]
            switch a {
            case "!", "-not": negateNext = true; i += 1; continue
            case "-name", "-iname":
                if i + 1 < args.count { namePatterns.append((args[i + 1], a == "-iname", negateNext)); i += 1 }
            case "-path", "-wholename": if i + 1 < args.count { pathPatterns.append(args[i + 1]); i += 1 }
            case "-type": if i + 1 < args.count { type = args[i + 1].first; i += 1 }
            case "-maxdepth": if i + 1 < args.count { maxDepth = Int(args[i + 1]) ?? Int.max; i += 1 }
            case "-mindepth": if i + 1 < args.count { minDepth = Int(args[i + 1]) ?? 0; i += 1 }
            case "-delete": delete = true
            case "-exec":
                var cmd: [String] = []
                i += 1
                while i < args.count, args[i] != ";", args[i] != "+" { cmd.append(args[i]); i += 1 }
                execCmd = cmd
            default: break
            }
            negateNext = false
            i += 1
        }
        var results: [String] = []
        for root in paths {
            let rootURL = sh.resolve(root)
            guard exists(rootURL) else { io.stderr.write("find: '\(root)': File o directory non esistente\n"); return (1, nil) }
            func visit(_ u: URL, display: String, depth: Int) {
                if depth > maxDepth { return }
                let name = depth == 0 ? (root as NSString).lastPathComponent : u.lastPathComponent
                let dir = isDir(u)
                var ok = depth >= minDepth
                if let t = type { ok = ok && ((t == "d" && dir) || (t == "f" && !dir) || (t == "l" && (try? fm.destinationOfSymbolicLink(atPath: u.path)) != nil)) }
                for (pat, ci, neg) in namePatterns {
                    let m = ci ? ShellPattern.regex(pat, caseInsensitive: true).map { $0.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil } ?? false
                               : ShellPattern.matches(name, pat)
                    ok = ok && (neg ? !m : m)
                }
                for pat in pathPatterns { ok = ok && ShellPattern.matches(display, pat) }
                if ok { results.append(display) }
                if dir, depth < maxDepth {
                    for n in ((try? fm.contentsOfDirectory(atPath: u.path)) ?? []).sorted() {
                        visit(u.appendingPathComponent(n), display: display == "/" ? "/\(n)" : "\(display)/\(n)", depth: depth + 1)
                    }
                }
            }
            visit(rootURL, display: root.hasSuffix("/") && root.count > 1 ? String(root.dropLast()) : root, depth: 0)
        }
        if delete {
            for r in results.reversed() { try? fm.removeItem(at: sh.resolve(r)) }
            return (0, nil)
        }
        if let cmd = execCmd {
            let script = results.map { r in
                cmd.map { $0 == "{}" ? sh.shellQuoteIfNeeded(r) : sh.shellQuoteIfNeeded($0) }.joined(separator: " ")
            }.joined(separator: "\n")
            return (0, script)
        }
        io.stdout.write(results.map { $0 + "\n" }.joined())
        return (0, nil)
    }

    static func zip(_ args: [String], _ io: ShIO, _ sh: ShellInterpreter) -> Int32 {
        let p = ParsedArgs(args)
        guard p.operands.count >= 2 else { io.stderr.write("zip: uso: zip [-r] archivio.zip file...\n"); return 1 }
        var archivePath = p.operands[0]
        if !archivePath.lowercased().hasSuffix(".zip") && !archivePath.lowercased().hasSuffix(".ipa") { archivePath += ".zip" }
        let archive = sh.resolve(archivePath)
        var entries: [(relative: String, url: URL)] = []
        for item in p.operands.dropFirst() {
            let u = sh.resolve(item)
            guard exists(u) else { io.stderr.write("zip warning: name not matched: \(item)\n"); continue }
            let relBase = item.hasPrefix("/") ? u.lastPathComponent : item
            if isDir(u) {
                guard p.flags.contains("r") else { continue }
                for f in ZipUtil.listFiles(in: u) { entries.append(((relBase as NSString).appendingPathComponent(f.relative), f.url)) }
            } else {
                entries.append((relBase, u))
            }
        }
        do {
            try ZipUtil.zip(entries: entries, to: archive)
            if !p.flags.contains("q") { for e in entries { io.stdout.write("  adding: \(e.relative) (deflated)\n") } }
        } catch {
            io.stderr.write("zip: \(error.localizedDescription)\n"); return 1
        }
        return 0
    }

    static func unzip(_ args: [String], _ io: ShIO, _ sh: ShellInterpreter) -> Int32 {
        var values: [Character: String] = [:]
        let p = ParsedArgs(args, valueFlags: ["d"], values: &values)
        guard let file = p.operands.first else { io.stderr.write("unzip: archivio mancante\n"); return 1 }
        let dest = sh.resolve(values["d"] ?? ".")
        do {
            do {
                // ZIPFoundation non sovrascrive: estraiamo in una cartella temporanea e uniamo
                let tmp = URL(fileURLWithPath: sh.host.tempDir).appendingPathComponent("unzip-\(UUID().uuidString)")
                try ZipUtil.unzip(sh.resolve(file), to: tmp)
                for n in try fm.contentsOfDirectory(atPath: tmp.path) {
                    try copyItem(tmp.appendingPathComponent(n), to: dest.appendingPathComponent(n), move: true, noClobber: p.flags.contains("n"))
                }
                try? fm.removeItem(at: tmp)
            }
            if !p.flags.contains("q") { io.stdout.write("Archive:  \(file)\n") }
        } catch {
            io.stderr.write("unzip: \(error.localizedDescription)\n"); return 1
        }
        return 0
    }
}
