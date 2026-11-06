import Foundation

enum TextCommands {
    static func err(_ io: ShIO, _ cmd: String) -> (String) -> Void {
        { io.stderr.write("\(cmd): \($0)\n") }
    }

    /// Converte una regex POSIX BRE in ERE (gestione di \( \) \{ \} \+ \? \|).
    static func breToERE(_ s: String) -> String {
        var out = ""
        let c = Array(s)
        var i = 0
        var inBracket = false
        while i < c.count {
            let ch = c[i]
            if inBracket {
                out.append(ch)
                if ch == "]" { inBracket = false }
                i += 1; continue
            }
            if ch == "[" { inBracket = true; out.append(ch); i += 1; if i < c.count, c[i] == "^" { out.append("^"); i += 1 }; if i < c.count, c[i] == "]" { out.append("\\]"); i += 1 }; continue }
            if ch == "\\", i + 1 < c.count {
                let n = c[i + 1]
                if "(){}+?|".contains(n) { out.append(n) } else { out.append("\\"); out.append(n) }
                i += 2; continue
            }
            if "(){}+?|".contains(ch) { out.append("\\"); out.append(ch); i += 1; continue }
            out.append(ch)
            i += 1
        }
        return out
    }

    /// Classi POSIX [[:alpha:]] -> ICU.
    static func posixClasses(_ s: String) -> String {
        s.replacingOccurrences(of: "[:alpha:]", with: "\\p{L}")
            .replacingOccurrences(of: "[:digit:]", with: "0-9")
            .replacingOccurrences(of: "[:alnum:]", with: "\\p{L}0-9")
            .replacingOccurrences(of: "[:space:]", with: "\\s")
            .replacingOccurrences(of: "[:upper:]", with: "A-Z")
            .replacingOccurrences(of: "[:lower:]", with: "a-z")
            .replacingOccurrences(of: "[:punct:]", with: "\\p{P}")
            .replacingOccurrences(of: "[:xdigit:]", with: "0-9A-Fa-f")
            .replacingOccurrences(of: "[:blank:]", with: " \\t")
    }

    static func headTail(_ name: String, _ args: [String], _ io: ShIO, _ sh: ShellInterpreter) -> Int32 {
        var count = 10
        var bytes: Int? = nil
        var fromStart = false
        var files: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "-n" || a == "-c", i + 1 < args.count {
                var v = args[i + 1]
                if v.hasPrefix("+") { fromStart = true; v.removeFirst() }
                if a == "-n" { count = Int(v) ?? 10 } else { bytes = Int(v) }
                i += 2; continue
            }
            if a.hasPrefix("-n") { var v = String(a.dropFirst(2)); if v.hasPrefix("+") { fromStart = true; v.removeFirst() }; count = Int(v) ?? 10; i += 1; continue }
            if a.hasPrefix("-c") { bytes = Int(a.dropFirst(2)); i += 1; continue }
            if a.hasPrefix("-"), let n = Int(a.dropFirst()) { count = n; i += 1; continue }
            if a == "-q" || a == "-f" || a == "-F" { i += 1; continue }
            files.append(a); i += 1
        }
        guard let text = ShellBuiltins.readInputs(files, io, sh, err(io, name)) else { return 1 }
        if let b = bytes {
            let chars = Array(text)
            io.stdout.write(name == "head" ? String(chars.prefix(b)) : String(chars.suffix(b)))
            return 0
        }
        let lines = ShellBuiltins.lines(text)
        var selected: [String]
        if name == "head" {
            selected = count >= 0 ? Array(lines.prefix(count)) : Array(lines.dropLast(-count))
        } else {
            selected = fromStart ? Array(lines.dropFirst(max(0, count - 1))) : Array(lines.suffix(count))
        }
        if !selected.isEmpty { io.stdout.write(selected.joined(separator: "\n") + "\n") }
        return 0
    }

    static func wc(_ args: [String], _ io: ShIO, _ sh: ShellInterpreter) -> Int32 {
        let p = ParsedArgs(args)
        var files = p.operands
        let onlyStdin = files.isEmpty
        if onlyStdin { files = ["-"] }
        for f in files {
            guard let text = ShellBuiltins.readInputs(f == "-" ? [] : [f], io, sh, err(io, "wc")) else { return 1 }
            let l = text.filter { $0 == "\n" }.count
            let w = text.split(whereSeparator: { $0.isWhitespace }).count
            let c = text.utf8.count
            let m = text.count
            var parts: [String] = []
            let any = p.flags.contains("l") || p.flags.contains("w") || p.flags.contains("c") || p.flags.contains("m")
            if !any || p.flags.contains("l") { parts.append(String(l)) }
            if !any || p.flags.contains("w") { parts.append(String(w)) }
            if !any || p.flags.contains("c") { parts.append(String(c)) }
            if p.flags.contains("m") { parts.append(String(m)) }
            let joined = onlyStdin && parts.count == 1 ? parts[0] : parts.map { String(repeating: " ", count: max(0, 7 - $0.count)) + $0 }.joined(separator: " ")
            io.stdout.write(joined + (onlyStdin ? "" : " \(f)") + "\n")
        }
        return 0
    }

    static func grep(_ name: String, _ args: [String], _ io: ShIO, _ sh: ShellInterpreter) -> Int32 {
        var patterns: [String] = []
        var files: [String] = []
        var flags = Set<Character>()
        var extended = name == "egrep"
        var fixed = name == "fgrep"
        var i = 0
        var maxCount: Int? = nil
        while i < args.count {
            let a = args[i]
            if a == "-e", i + 1 < args.count { patterns.append(args[i + 1]); i += 2; continue }
            if a == "-m", i + 1 < args.count { maxCount = Int(args[i + 1]); i += 2; continue }
            if a == "--" { files.append(contentsOf: args[(i + 1)...]); break }
            if a.hasPrefix("--") {
                switch a {
                case "--quiet", "--silent": flags.insert("q")
                case "--count": flags.insert("c")
                case "--invert-match": flags.insert("v")
                case "--ignore-case": flags.insert("i")
                case "--extended-regexp": extended = true
                case "--fixed-strings": fixed = true
                case "--recursive": flags.insert("r")
                case "--files-with-matches": flags.insert("l")
                case "--only-matching": flags.insert("o")
                case "--line-number": flags.insert("n")
                default: break
                }
                i += 1; continue
            }
            if a.hasPrefix("-") && a.count > 1 {
                for f in a.dropFirst() {
                    if f == "E" { extended = true } else if f == "F" { fixed = true } else if f == "P" { extended = true } else { flags.insert(f) }
                }
                i += 1; continue
            }
            if patterns.isEmpty { patterns.append(a) } else { files.append(a) }
            i += 1
        }
        guard !patterns.isEmpty else { io.stderr.write("grep: pattern mancante\n"); return 2 }
        var opts: NSRegularExpression.Options = []
        if flags.contains("i") { opts.insert(.caseInsensitive) }
        var regexes: [NSRegularExpression] = []
        for p in patterns.flatMap({ $0.components(separatedBy: "\n") }) {
            var src = fixed ? NSRegularExpression.escapedPattern(for: p) : (extended ? p : breToERE(p))
            src = posixClasses(src)
            if flags.contains("w") { src = "\\b(?:" + src + ")\\b" }
            if flags.contains("x") { src = "^(?:" + src + ")$" }
            guard let r = try? NSRegularExpression(pattern: src, options: opts) else {
                io.stderr.write("grep: regex non valida: \(p)\n"); return 2
            }
            regexes.append(r)
        }

        var inputs: [(String, String)] = []
        if files.isEmpty {
            if flags.contains("r") || flags.contains("R") { files = ["."] } else { inputs.append(("(standard input)", io.stdin.readAll())) }
        }
        for f in files {
            let u = sh.resolve(f)
            if FileCommands.isDir(u) {
                if flags.contains("r") || flags.contains("R") {
                    for e in ZipUtil.listFiles(in: u) where ShellBuiltins.isText(e.url) {
                        let display = f == "." ? e.relative : (f as NSString).appendingPathComponent(e.relative)
                        inputs.append((display, (try? String(contentsOf: e.url, encoding: .utf8)) ?? ""))
                    }
                } else if !flags.contains("s") { io.stderr.write("grep: \(f): È una directory\n") }
                continue
            }
            guard let t = try? String(contentsOf: u, encoding: .utf8) else {
                if !flags.contains("s") { io.stderr.write("grep: \(f): File o directory non esistente\n") }
                continue
            }
            inputs.append((f, t))
        }
        let showNames = inputs.count > 1 && !flags.contains("h") || flags.contains("H")
        var anyMatch = false
        for (fname, text) in inputs {
            var count = 0
            for (idx, line) in ShellBuiltins.lines(text).enumerated() {
                if let m = maxCount, count >= m { break }
                let range = NSRange(line.startIndex..., in: line)
                let matchedRegex = regexes.first { $0.firstMatch(in: line, range: range) != nil }
                let matched = (matchedRegex != nil) != flags.contains("v")
                guard matched else { continue }
                anyMatch = true
                count += 1
                if flags.contains("q") { return 0 }
                if flags.contains("l") || flags.contains("c") { continue }
                let prefix = (showNames ? "\(fname):" : "") + (flags.contains("n") ? "\(idx + 1):" : "")
                if flags.contains("o"), let r = matchedRegex {
                    for m in r.matches(in: line, range: range) {
                        if let rr = Range(m.range, in: line) { io.stdout.write(prefix + String(line[rr]) + "\n") }
                    }
                } else {
                    io.stdout.write(prefix + line + "\n")
                }
            }
            if flags.contains("l") && count > 0 { io.stdout.write(fname + "\n") }
            if flags.contains("c") { io.stdout.write((showNames ? "\(fname):" : "") + "\(count)\n") }
        }
        return anyMatch ? 0 : 1
    }

    // MARK: sed

    private struct SedCommand {
        enum Address { case line(Int), last, regex(NSRegularExpression) }
        var address: Address?
        var address2: Address?
        var negate = false
        var cmd: Character
        var regex: NSRegularExpression?
        var replacement = ""
        var global = false
        var occurrence = 1
        var printAfter = false
        var text = ""
    }

    static func sed(_ args: [String], _ io: ShIO, _ sh: ShellInterpreter) -> Int32 {
        var scripts: [String] = []
        var files: [String] = []
        var inPlace = false
        var quiet = false
        var extended = false
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "-e", i + 1 < args.count { scripts.append(args[i + 1]); i += 2; continue }
            if a == "-f", i + 1 < args.count {
                scripts.append((try? String(contentsOf: sh.resolve(args[i + 1]), encoding: .utf8)) ?? ""); i += 2; continue
            }
            if a == "-i" || a.hasPrefix("-i") || a == "--in-place" {
                inPlace = true
                // macOS: -i '' (suffisso vuoto separato)
                if a == "-i", i + 1 < args.count, args[i + 1].isEmpty { i += 1 }
                i += 1; continue
            }
            if a == "-n" || a == "--quiet" { quiet = true; i += 1; continue }
            if a == "-E" || a == "-r" { extended = true; i += 1; continue }
            if a.hasPrefix("-") && a.count > 1 {
                for f in a.dropFirst() { if f == "n" { quiet = true }; if f == "E" || f == "r" { extended = true }; if f == "i" { inPlace = true } }
                i += 1; continue
            }
            if scripts.isEmpty { scripts.append(a) } else { files.append(a) }
            i += 1
        }
        let commands: [SedCommand]
        do { commands = try parseSed(scripts.joined(separator: "\n"), extended: extended) } catch {
            io.stderr.write("sed: \(error.localizedDescription)\n"); return 1
        }
        func process(_ text: String) -> String {
            let lines = ShellBuiltins.lines(text)
            var out = ""
            var rangeActive = Array(repeating: false, count: commands.count)
            lineLoop: for (n, original) in lines.enumerated() {
                var line = original
                var deleted = false
                let isLast = n == lines.count - 1
                for (ci, c) in commands.enumerated() {
                    func matches(_ a: SedCommand.Address) -> Bool {
                        switch a {
                        case .line(let l): return l == n + 1
                        case .last: return isLast
                        case .regex(let r): return r.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
                        }
                    }
                    var applies = true
                    if let a1 = c.address {
                        if let a2 = c.address2 {
                            if rangeActive[ci] {
                                applies = true
                                if matches(a2) { rangeActive[ci] = false }
                            } else if matches(a1) {
                                applies = true
                                rangeActive[ci] = true
                                if case .line(let l2) = a2, l2 <= n + 1 { rangeActive[ci] = false }
                            } else { applies = false }
                        } else {
                            applies = matches(a1)
                        }
                    }
                    if c.negate { applies.toggle() }
                    guard applies else { continue }
                    switch c.cmd {
                    case "s":
                        guard let r = c.regex else { continue }
                        let range = NSRange(line.startIndex..., in: line)
                        let ms = r.matches(in: line, range: range)
                        if ms.isEmpty { continue }
                        let ns = NSMutableString(string: line)
                        var targets = ms
                        if !c.global { targets = c.occurrence - 1 < ms.count ? [ms[c.occurrence - 1]] : [] }
                        for m in targets.reversed() {
                            let rep = r.replacementString(for: m, in: line, offset: 0, template: c.replacement)
                            ns.replaceCharacters(in: m.range, with: rep)
                        }
                        line = ns as String
                        if c.printAfter { out += line + "\n" }
                    case "d": deleted = true; break
                    case "p": out += line + "\n"
                    case "q":
                        if !quiet { out += line + "\n" }
                        break lineLoop
                    case "a": if !quiet { out += line + "\n" }; line = c.text; if quiet { continue }
                    case "i": out += c.text + "\n"
                    case "c": line = c.text
                    case "=": out += "\(n + 1)\n"
                    default: break
                    }
                    if deleted { break }
                }
                if !deleted && !quiet { out += line + "\n" }
            }
            return out
        }
        if files.isEmpty {
            io.stdout.write(process(io.stdin.readAll()))
            return 0
        }
        for f in files {
            let u = sh.resolve(f)
            guard let text = try? String(contentsOf: u, encoding: .utf8) else {
                io.stderr.write("sed: impossibile leggere \(f): File o directory non esistente\n"); return 2
            }
            let result = process(text)
            if inPlace { try? result.write(to: u, atomically: true, encoding: .utf8) } else { io.stdout.write(result) }
        }
        return 0
    }

    private static func parseSed(_ script: String, extended: Bool) throws -> [SedCommand] {
        var cmds: [SedCommand] = []
        let c = Array(script)
        var i = 0
        func skipWS() { while i < c.count, c[i] == " " || c[i] == "\t" || c[i] == ";" || c[i] == "\n" { i += 1 } }
        func readDelimited(_ d: Character) throws -> String {
            var s = ""
            while i < c.count, c[i] != d {
                if c[i] == "\\", i + 1 < c.count {
                    if c[i + 1] == d { s.append(d) } else if c[i + 1] == "n" { s.append("\n") } else { s.append("\\"); s.append(c[i + 1]) }
                    i += 2; continue
                }
                s.append(c[i]); i += 1
            }
            guard i < c.count else { throw ShellRuntimeError(message: "comando 's' non terminato") }
            i += 1
            return s
        }
        func makeRegex(_ s: String, _ ci: Bool) throws -> NSRegularExpression {
            let src = posixClasses(extended ? s : breToERE(s))
            do { return try NSRegularExpression(pattern: src.isEmpty ? "^" : src, options: ci ? [.caseInsensitive] : []) }
            catch { throw ShellRuntimeError(message: "regex non valida: \(s)") }
        }
        func readAddress() throws -> SedCommand.Address? {
            guard i < c.count else { return nil }
            if c[i].isNumber {
                var n = ""
                while i < c.count, c[i].isNumber { n.append(c[i]); i += 1 }
                return .line(Int(n) ?? 1)
            }
            if c[i] == "$" { i += 1; return .last }
            if c[i] == "/" || c[i] == "\\" {
                var d: Character = "/"
                if c[i] == "\\" { i += 1; d = c[i] }
                i += 1
                let re = try readDelimited(d)
                var ci = false
                if i < c.count, c[i] == "I" { ci = true; i += 1 }
                return .regex(try makeRegex(re, ci))
            }
            return nil
        }
        while true {
            skipWS()
            guard i < c.count else { break }
            if c[i] == "#" { while i < c.count, c[i] != "\n" { i += 1 }; continue }
            let a1 = try readAddress()
            var a2: SedCommand.Address? = nil
            if a1 != nil, i < c.count, c[i] == "," { i += 1; a2 = try readAddress() }
            while i < c.count, c[i] == " " { i += 1 }
            var negate = false
            if i < c.count, c[i] == "!" { negate = true; i += 1 }
            guard i < c.count else { break }
            let ch = c[i]
            i += 1
            var cmd = SedCommand(address: a1, address2: a2, negate: negate, cmd: ch)
            switch ch {
            case "s", "y":
                guard i < c.count else { throw ShellRuntimeError(message: "comando 's' incompleto") }
                let d = c[i]; i += 1
                let pattern = try readDelimited(d)
                let rep = try readDelimited(d)
                var ci = false
                while i < c.count, "gIipe0123456789w".contains(c[i]) {
                    let f = c[i]
                    if f == "g" { cmd.global = true }
                    else if f == "i" || f == "I" { ci = true }
                    else if f == "p" { cmd.printAfter = true }
                    else if f.isNumber { cmd.occurrence = Int(String(f)) ?? 1 }
                    i += 1
                }
                cmd.regex = try makeRegex(pattern, ci)
                cmd.replacement = sedReplacementTemplate(rep)
            case "a", "i", "c":
                while i < c.count, c[i] == " " || c[i] == "\\" { i += 1 }
                if i < c.count, c[i] == "\n" { i += 1 }
                var t = ""
                while i < c.count, c[i] != "\n" { t.append(c[i]); i += 1 }
                cmd.text = t
            case "{", "}":
                continue
            default:
                break
            }
            cmds.append(cmd)
        }
        return cmds
    }

    /// & -> $0, \1 -> $1, escape di '$' e '\' per i template di NSRegularExpression.
    private static func sedReplacementTemplate(_ rep: String) -> String {
        var out = ""
        let c = Array(rep)
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "\\", i + 1 < c.count {
                let n = c[i + 1]
                if n.isNumber { out += "$\(n)" }
                else if n == "n" { out += "\n" }
                else if n == "t" { out += "\t" }
                else if n == "&" { out += "&" }
                else if n == "\\" { out += "\\\\" }
                else if n == "$" { out += "\\$" }
                else { out.append(n) }
                i += 2; continue
            }
            if ch == "&" { out += "$0"; i += 1; continue }
            if ch == "$" { out += "\\$"; i += 1; continue }
            out.append(ch)
            i += 1
        }
        return out
    }

    // MARK: awk (sottoinsieme)

    static func awk(_ args: [String], _ io: ShIO, _ sh: ShellInterpreter) -> Int32 {
        var fs: String? = nil
        var vars: [String: String] = [:]
        var program: String? = nil
        var files: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "-F", i + 1 < args.count { fs = args[i + 1]; i += 2; continue }
            if a.hasPrefix("-F") { fs = String(a.dropFirst(2)); i += 1; continue }
            if a == "-v", i + 1 < args.count {
                let (n, v, _) = ShellBuiltins.splitAssignment(args[i + 1]); vars[n] = v ?? ""; i += 2; continue
            }
            if program == nil { program = a } else { files.append(a) }
            i += 1
        }
        guard let prog = program else { io.stderr.write("awk: programma mancante\n"); return 2 }
        guard let text = ShellBuiltins.readInputs(files, io, sh, err(io, "awk")) else { return 2 }
        do {
            let interp = try MiniAwk(program: prog, fs: fs, vars: vars)
            io.stdout.write(interp.run(text))
            return 0
        } catch {
            io.stderr.write("awk: \(error.localizedDescription) (l'interprete iOS supporta solo un sottoinsieme di awk: pattern, print/printf, NR, NF, $n, BEGIN/END)\n")
            return 2
        }
    }

    // MARK: cut / tr / sort / uniq

    static func cut(_ args: [String], _ io: ShIO, _ sh: ShellInterpreter) -> Int32 {
        var values: [Character: String] = [:]
        let p = ParsedArgs(args, valueFlags: ["d", "f", "c", "b"], values: &values)
        let delim = values["d"].flatMap { $0.first } ?? "\t"
        guard let text = ShellBuiltins.readInputs(p.operands, io, sh, err(io, "cut")) else { return 1 }
        func parseList(_ s: String) -> [ClosedRange<Int>] {
            s.split(separator: ",").compactMap { part in
                let comps = part.split(separator: "-", omittingEmptySubsequences: false)
                if comps.count == 1, let n = Int(comps[0]) { return n...n }
                let a = Int(comps[0]) ?? 1
                let b = comps.count > 1 ? (Int(comps[1]) ?? Int.max / 2) : a
                return a...max(a, b)
            }
        }
        var out = ""
        for line in ShellBuiltins.lines(text) {
            if let f = values["f"] {
                let fields = line.split(separator: delim, omittingEmptySubsequences: false).map(String.init)
                if fields.count == 1 && !p.flags.contains("s") { out += line + "\n"; continue }
                var picked: [String] = []
                for (idx, field) in fields.enumerated() where parseList(f).contains(where: { $0.contains(idx + 1) }) { picked.append(field) }
                out += picked.joined(separator: String(delim)) + "\n"
            } else if let cl = values["c"] ?? values["b"] {
                let chars = Array(line)
                var picked = ""
                for (idx, ch) in chars.enumerated() where parseList(cl).contains(where: { $0.contains(idx + 1) }) { picked.append(ch) }
                out += picked + "\n"
            } else {
                io.stderr.write("cut: specificare -f, -c o -b\n"); return 1
            }
        }
        io.stdout.write(out)
        return 0
    }

    static func expandTrSet(_ s: String) -> [Character] {
        var t = s
        let classes: [String: String] = [
            "[:upper:]": "ABCDEFGHIJKLMNOPQRSTUVWXYZ", "[:lower:]": "abcdefghijklmnopqrstuvwxyz",
            "[:digit:]": "0123456789", "[:space:]": " \t\n\r\u{0B}\u{0C}", "[:blank:]": " \t",
            "[:alpha:]": "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz",
            "[:alnum:]": "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
            "[:punct:]": "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
        ]
        for (k, v) in classes { t = t.replacingOccurrences(of: k, with: v) }
        t = ShellBuiltins.processEscapes(t).0
        let c = Array(t)
        var out: [Character] = []
        var i = 0
        while i < c.count {
            if i + 2 < c.count, c[i + 1] == "-", let a = c[i].unicodeScalars.first?.value, let b = c[i + 2].unicodeScalars.first?.value, a <= b {
                for v in a...b { if let u = Unicode.Scalar(v) { out.append(Character(u)) } }
                i += 3
            } else {
                out.append(c[i]); i += 1
            }
        }
        return out
    }

    static func tr(_ args: [String], _ io: ShIO, _ sh: ShellInterpreter) -> Int32 {
        let p = ParsedArgs(args)
        let text = io.stdin.readAll()
        guard let s1 = p.operands.first else { io.stderr.write("tr: operando mancante\n"); return 1 }
        var set1 = expandTrSet(s1)
        if p.flags.contains("c") || p.flags.contains("C") {
            let all = Set(text)
            set1 = all.filter { !set1.contains($0) }.sorted()
        }
        var out = ""
        if p.flags.contains("d") {
            let del = Set(set1)
            out = String(text.filter { !del.contains($0) })
        } else if p.operands.count > 1 {
            var set2 = expandTrSet(p.operands[1])
            if set2.isEmpty { set2 = [" "] }
            while set2.count < set1.count { set2.append(set2.last!) }
            var map: [Character: Character] = [:]
            for (i, ch) in set1.enumerated() { map[ch] = set2[i] }
            out = String(text.map { map[$0] ?? $0 })
        } else {
            out = text
        }
        if p.flags.contains("s") {
            let sq = Set(p.operands.count > 1 ? expandTrSet(p.operands[1]) : set1)
            var res = ""
            for ch in out { if let l = res.last, l == ch, sq.contains(ch) { continue }; res.append(ch) }
            out = res
        }
        io.stdout.write(out)
        return 0
    }

    static func sort(_ args: [String], _ io: ShIO, _ sh: ShellInterpreter) -> Int32 {
        var values: [Character: String] = [:]
        let p = ParsedArgs(args, valueFlags: ["k", "t", "o"], values: &values)
        guard let text = ShellBuiltins.readInputs(p.operands, io, sh, err(io, "sort")) else { return 2 }
        var lines = ShellBuiltins.lines(text)
        let sep = values["t"]?.first
        let keyField = values["k"].flatMap { Int($0.split(separator: ",").first ?? "") }
        func key(_ l: String) -> String {
            guard let k = keyField else { return l }
            let fields = sep != nil ? l.split(separator: sep!, omittingEmptySubsequences: false).map(String.init)
                                    : l.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            return k - 1 < fields.count ? fields[k - 1] : ""
        }
        let numeric = p.flags.contains("n") || p.flags.contains("g") || p.flags.contains("h")
        let version = p.flags.contains("V")
        let fold = p.flags.contains("f")
        lines.sort { a, b in
            let ka = key(a), kb = key(b)
            if numeric {
                let na = Double(ka.trimmingCharacters(in: .whitespaces).prefix { "0123456789.-".contains($0) }) ?? 0
                let nb = Double(kb.trimmingCharacters(in: .whitespaces).prefix { "0123456789.-".contains($0) }) ?? 0
                if na != nb { return na < nb }
                return ka < kb
            }
            if version { return ka.compare(kb, options: .numeric) == .orderedAscending }
            if fold { return ka.lowercased() < kb.lowercased() }
            return ka < kb
        }
        if p.flags.contains("r") { lines.reverse() }
        if p.flags.contains("u") {
            var seen = Set<String>()
            lines = lines.filter { seen.insert(key($0)).inserted }
        }
        let result = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        if let o = values["o"] { try? result.write(to: sh.resolve(o), atomically: true, encoding: .utf8) } else { io.stdout.write(result) }
        return 0
    }

    static func uniq(_ args: [String], _ io: ShIO, _ sh: ShellInterpreter) -> Int32 {
        let p = ParsedArgs(args)
        guard let text = ShellBuiltins.readInputs(Array(p.operands.prefix(1)), io, sh, err(io, "uniq")) else { return 1 }
        var groups: [(String, Int)] = []
        for l in ShellBuiltins.lines(text) {
            let cmpL = p.flags.contains("i") ? l.lowercased() : l
            if let last = groups.last, (p.flags.contains("i") ? last.0.lowercased() : last.0) == cmpL {
                groups[groups.count - 1].1 += 1
            } else { groups.append((l, 1)) }
        }
        var out = ""
        for (l, n) in groups {
            if p.flags.contains("d") && n < 2 { continue }
            if p.flags.contains("u") && n > 1 { continue }
            out += (p.flags.contains("c") ? String(format: "%7d ", n) : "") + l + "\n"
        }
        io.stdout.write(out)
        return 0
    }
}

// MARK: - awk minimale

struct MiniAwk {
    struct Rule {
        enum Pattern { case always, begin, end, regex(NSRegularExpression), expr(String) }
        var pattern: Pattern
        var actions: [String]   // istruzioni separate da ';'
    }
    var rules: [Rule] = []
    var fs: String?
    var vars: [String: String]

    init(program: String, fs: String?, vars: [String: String]) throws {
        self.fs = fs
        self.vars = vars
        let c = Array(program)
        var i = 0
        while i < c.count {
            while i < c.count, c[i].isWhitespace || c[i] == ";" { i += 1 }
            guard i < c.count else { break }
            var pattern: Rule.Pattern = .always
            if c[i] == "/" {
                i += 1
                var re = ""
                while i < c.count, c[i] != "/" { if c[i] == "\\", i + 1 < c.count { re.append(c[i]); i += 1 }; re.append(c[i]); i += 1 }
                i += 1
                guard let r = try? NSRegularExpression(pattern: re) else { throw ShellRuntimeError(message: "regex non valida /\(re)/") }
                pattern = .regex(r)
            } else if c[i] != "{" {
                var p = ""
                while i < c.count, c[i] != "{" { p.append(c[i]); i += 1 }
                let t = p.trimmingCharacters(in: .whitespaces)
                pattern = t == "BEGIN" ? .begin : (t == "END" ? .end : .expr(t))
            }
            while i < c.count, c[i].isWhitespace { i += 1 }
            var actions: [String] = ["print"]
            if i < c.count, c[i] == "{" {
                i += 1
                var body = ""
                var depth = 0
                var inStr = false
                while i < c.count {
                    if c[i] == "\"" { inStr.toggle() }
                    if !inStr && c[i] == "{" { depth += 1 }
                    if !inStr && c[i] == "}" { if depth == 0 { break }; depth -= 1 }
                    body.append(c[i]); i += 1
                }
                i += 1
                actions = MiniAwk.splitStatements(body)
            }
            rules.append(Rule(pattern: pattern, actions: actions))
        }
    }

    static func splitStatements(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inStr = false
        for ch in s {
            if ch == "\"" { inStr.toggle() }
            if !inStr && (ch == ";" || ch == "\n") {
                let t = cur.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append(t) }
                cur = ""
            } else { cur.append(ch) }
        }
        let t = cur.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { out.append(t) }
        return out
    }

    func run(_ text: String) -> String {
        var out = ""
        var env = vars
        var nr = 0
        var fields: [String] = []
        var record = ""
        func split(_ line: String) -> [String] {
            if let f = fs, !f.isEmpty, f != " " {
                if f.count == 1 { return line.split(separator: Character(f), omittingEmptySubsequences: false).map(String.init) }
                return line.components(separatedBy: f)
            }
            return line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        }
        func value(_ token: String) -> String {
            let t = token.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("\"") && t.hasSuffix("\"") && t.count >= 2 {
                return ShellBuiltins.processEscapes(String(t.dropFirst().dropLast())).0
            }
            if t == "$0" { return record }
            if t == "NR" { return String(nr) }
            if t == "NF" { return String(fields.count) }
            if t == "$NF" { return fields.last ?? "" }
            if t.hasPrefix("$NF-"), let k = Int(t.dropFirst(4)) { let idx = fields.count - k; return idx >= 1 && idx <= fields.count ? fields[idx - 1] : "" }
            if t.hasPrefix("$"), let n = Int(t.dropFirst()) { return n >= 1 && n <= fields.count ? fields[n - 1] : (n == 0 ? record : "") }
            if let d = Double(t) { return JSONValue.formatNumber(d) }
            if t.hasPrefix("length(") {
                let inner = String(t.dropFirst(7).dropLast())
                return String((inner.isEmpty ? record : value(inner)).count)
            }
            if t == "length" { return String(record.count) }
            if t.hasPrefix("toupper(") { return value(String(t.dropFirst(8).dropLast())).uppercased() }
            if t.hasPrefix("tolower(") { return value(String(t.dropFirst(8).dropLast())).lowercased() }
            return env[t] ?? ""
        }
        func evalList(_ s: String) -> [String] {
            // elementi separati da virgole fuori dalle stringhe; concatenazione per spazi
            var items: [String] = []
            var cur = ""
            var inStr = false
            var depth = 0
            for ch in s {
                if ch == "\"" { inStr.toggle() }
                if !inStr { if ch == "(" { depth += 1 }; if ch == ")" { depth -= 1 } }
                if ch == "," && !inStr && depth == 0 { items.append(cur); cur = "" } else { cur.append(ch) }
            }
            if !cur.trimmingCharacters(in: .whitespaces).isEmpty { items.append(cur) }
            return items.map { item in
                var parts: [String] = []
                var tok = ""
                var inS = false
                var d = 0
                for ch in item {
                    if ch == "\"" { inS.toggle() }
                    if !inS { if ch == "(" { d += 1 }; if ch == ")" { d -= 1 } }
                    if ch == " " && !inS && d == 0 { if !tok.isEmpty { parts.append(tok); tok = "" } } else { tok.append(ch) }
                }
                if !tok.isEmpty { parts.append(tok) }
                return parts.map { value($0) }.joined()
            }
        }
        func condition(_ e: String) -> Bool {
            for op in ["==", "!=", ">=", "<=", ">", "<", "~"] {
                if let r = e.range(of: op) {
                    let l = value(String(e[..<r.lowerBound])), rv = value(String(e[r.upperBound...]))
                    let ln = Double(l), rn = Double(rv)
                    switch op {
                    case "==": return l == rv
                    case "!=": return l != rv
                    case ">=": return (ln ?? 0) >= (rn ?? 0)
                    case "<=": return (ln ?? 0) <= (rn ?? 0)
                    case ">": return (ln ?? 0) > (rn ?? 0)
                    case "<": return (ln ?? 0) < (rn ?? 0)
                    default:
                        let pat = String(e[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " /"))
                        return l.range(of: pat, options: .regularExpression) != nil
                    }
                }
            }
            let v = value(e)
            return !v.isEmpty && v != "0"
        }
        func execute(_ actions: [String]) {
            for a in actions {
                if a == "print" { out += record + "\n"; continue }
                if a.hasPrefix("print ") || a.hasPrefix("print(") {
                    out += evalList(String(a.dropFirst(5))).joined(separator: " ") + "\n"
                } else if a.hasPrefix("printf") {
                    var items = evalList(String(a.dropFirst(6)).trimmingCharacters(in: CharacterSet(charactersIn: " ()")))
                    if items.isEmpty { continue }
                    let fmt = items.removeFirst()
                    out += Printf.format(fmt, items)
                } else if let eq = a.range(of: "+=") {
                    let n = a[..<eq.lowerBound].trimmingCharacters(in: .whitespaces)
                    env[n] = JSONValue.formatNumber((Double(env[n] ?? "0") ?? 0) + (Double(value(String(a[eq.upperBound...]))) ?? 0))
                } else if a.hasSuffix("++") {
                    let n = String(a.dropLast(2)).trimmingCharacters(in: .whitespaces)
                    env[n] = JSONValue.formatNumber((Double(env[n] ?? "0") ?? 0) + 1)
                } else if let eq = a.range(of: "="), !a.contains("==") {
                    let n = a[..<eq.lowerBound].trimmingCharacters(in: .whitespaces)
                    env[n] = evalList(String(a[eq.upperBound...])).joined(separator: " ")
                }
            }
        }
        for r in rules { if case .begin = r.pattern { execute(r.actions) } }
        for line in ShellBuiltins.lines(text) {
            nr += 1
            record = line
            fields = split(line)
            for r in rules {
                switch r.pattern {
                case .always: execute(r.actions)
                case .regex(let re): if re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil { execute(r.actions) }
                case .expr(let e): if condition(e) { execute(r.actions) }
                default: break
                }
            }
        }
        for r in rules { if case .end = r.pattern { execute(r.actions) } }
        return out
    }
}
