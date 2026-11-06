import Foundation
import CryptoKit

/// Comandi integrati dell'interprete. Su iOS non è possibile eseguire processi esterni
/// (fork/exec sono vietati dalla sandbox), quindi i comandi Unix più usati negli script CI
/// sono reimplementati qui in Swift.
enum ShellBuiltins {
    static let implemented: Set<String> = [
        ":", "true", "false", "echo", "printf", "cd", "pwd", "export", "unset", "set", "shift", "exit", "return",
        "break", "continue", "test", "[", "read", "local", "declare", "typeset", "readonly", "source", ".", "eval",
        "command", "type", "which", "hash", "sleep", "env", "printenv", "cat", "ls", "mkdir", "rmdir", "rm", "cp",
        "mv", "touch", "ln", "chmod", "chown", "head", "tail", "wc", "grep", "egrep", "fgrep", "sed", "awk", "cut",
        "tr", "sort", "uniq", "tee", "basename", "dirname", "realpath", "readlink", "date", "seq", "xargs", "find",
        "uname", "whoami", "hostname", "id", "base64", "sha256sum", "sha1sum", "md5sum", "shasum", "md5",
        "zip", "unzip", "curl", "wget", "jq", "git", "trap", "wait", "ulimit", "umask", "shopt", "alias",
        "unalias", "mktemp", "nproc", "bash", "sh", "yes", "stat", "du", "df", "file", "rev", "fold", "nl",
        "paste", "comm", "diff", "cmp", "let", "getopts", "times", "logger", "tput", "clear", "ps", "kill", "sync",
        "sw_vers", "arch", "expr", "timeout", "nohup", "time", "exec"
    ]

    static let realRunnerTools: Set<String> = [
        "xcodebuild", "xcrun", "swift", "swiftc", "xcodegen", "xcode-select", "security", "codesign", "plutil",
        "pod", "carthage", "fastlane", "bundle", "ruby", "gem", "node", "npm", "npx", "yarn", "pnpm", "python",
        "python3", "pip", "pip3", "java", "javac", "gradle", "mvn", "go", "cargo", "rustc", "dotnet", "docker",
        "brew", "apt", "apt-get", "sudo", "make", "cmake", "gcc", "clang", "g++", "clang++", "gh", "tar", "gzip",
        "gunzip", "xz", "ssh", "scp", "rsync", "openssl", "perl", "php", "flutter", "dart", "pwsh", "powershell",
        "terraform", "kubectl", "helm", "aws", "az", "gcloud", "deno", "bun", "zsh", "agvtool", "simctl", "lipo",
        "ditto", "hdiutil", "pkgbuild", "productbuild", "notarytool", "altool", "xcpretty", "xcbeautify", "jarsigner"
    ]

    static func notFoundMessage(_ name: String) -> String {
        if realRunnerTools.contains(name) {
            return "\(name): comando non disponibile nel runner iOS (la sandbox di iOS non consente processi esterni). " +
                "Esegui il workflow con \"Esegui su GitHub\" per usare un runner reale.\n"
        }
        return "bash: \(name): comando non trovato\n"
    }

    static func unescapedIndex(of ch: Character, in s: String) -> String.Index? {
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\\" { i = s.index(after: i); if i < s.endIndex { i = s.index(after: i) }; continue }
            if s[i] == ch { return i }
            i = s.index(after: i)
        }
        return nil
    }

    // MARK: Dispatch

    static func run(_ argv: [String], _ io: ShIO, _ sh: ShellInterpreter) async throws -> Int32? {
        let name = argv[0]
        let args = Array(argv.dropFirst())
        let state = sh.state
        func err(_ s: String) { io.stderr.write("\(name): \(s)\n") }

        switch name {
        case ":", "true", "sync", "wait", "ulimit", "umask", "shopt", "alias", "unalias", "hash", "logger", "clear", "times":
            return 0
        case "false":
            return 1

        case "echo":
            var newline = true
            var escapes = false
            var rest = args
            while let f = rest.first, f.hasPrefix("-"), f.count > 1, f.dropFirst().allSatisfy({ "neE".contains($0) }) {
                if f.contains("n") { newline = false }
                if f.contains("e") { escapes = true }
                if f.contains("E") { escapes = false }
                rest.removeFirst()
            }
            var text = rest.joined(separator: " ")
            if escapes {
                let (t, stop) = processEscapes(text)
                text = t
                if stop { newline = false }
            }
            io.stdout.write(text + (newline ? "\n" : ""))
            return 0

        case "printf":
            var a = args
            var targetVar: String? = nil
            if a.first == "-v", a.count > 1 { targetVar = a[1]; a.removeFirst(2) }
            if a.first == "--" { a.removeFirst() }
            guard let fmt = a.first else { err("uso: printf formato [argomenti]"); return 2 }
            let out = Printf.format(fmt, Array(a.dropFirst()))
            if let v = targetVar { state.setVar(v, out) } else { io.stdout.write(out) }
            return 0

        case "cd":
            var target = args.first(where: { !$0.hasPrefix("-") || $0 == "-" }) ?? (state.vars["HOME"] ?? sh.host.homeDir)
            if target == "-" { target = state.vars["OLDPWD"] ?? state.cwd; io.stdout.write(target + "\n") }
            let url = sh.resolve(target)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                err("\(target): Directory non esistente"); return 1
            }
            state.vars["OLDPWD"] = state.cwd
            state.cwd = url.path
            return 0

        case "pwd":
            io.stdout.write(state.cwd + "\n")
            return 0

        case "export", "declare", "typeset", "readonly", "local":
            var exportFlag = name == "export"
            var unexport = false
            var printMode = false
            var items: [String] = []
            for a in args {
                if a.hasPrefix("-") && items.isEmpty && !a.contains("=") {
                    if a.contains("x") { exportFlag = true }
                    if a == "-n" { unexport = true }
                    if a.contains("p") { printMode = true }
                    continue
                }
                items.append(a)
            }
            if items.isEmpty && (printMode || name == "export" || name == "declare") {
                for k in (exportFlag ? Array(state.exported) : Array(state.vars.keys)).sorted() {
                    io.stdout.write("declare -x \(k)=\"\(state.vars[k] ?? "")\"\n")
                }
                return 0
            }
            for item in items {
                let (n, v, append) = splitAssignment(item)
                if name == "local" { state.declareLocal(n) }
                if let v = v {
                    let nv = append ? (state.vars[n] ?? "") + v : v
                    state.setVar(n, nv, export: exportFlag)
                } else if name == "local" && state.vars[n] == nil {
                    state.vars[n] = ""
                }
                if exportFlag && !unexport { state.exported.insert(n) }
                if unexport { state.exported.remove(n) }
            }
            return 0

        case "unset":
            var functions = false
            for a in args {
                if a == "-f" { functions = true; continue }
                if a == "-v" { continue }
                if functions { state.functions.removeValue(forKey: a) } else { state.unsetVar(a) }
            }
            return 0

        case "set":
            if args.isEmpty {
                for k in state.vars.keys.sorted() { io.stdout.write("\(k)=\(state.vars[k] ?? "")\n") }
                return 0
            }
            var i = 0
            while i < args.count {
                let a = args[i]
                if a == "--" { state.positional = Array(args[(i + 1)...]); return 0 }
                if a == "-o" || a == "+o" {
                    let on = a == "-o"
                    if i + 1 < args.count {
                        switch args[i + 1] {
                        case "errexit": state.errexit = on
                        case "pipefail": state.pipefail = on
                        case "nounset": state.nounset = on
                        case "xtrace": state.xtrace = on
                        case "noglob": state.noglob = on
                        default: break
                        }
                        i += 2; continue
                    }
                    i += 1; continue
                }
                if (a.hasPrefix("-") || a.hasPrefix("+")) && a.count > 1 {
                    let on = a.hasPrefix("-")
                    for f in a.dropFirst() {
                        switch f {
                        case "e": state.errexit = on
                        case "u": state.nounset = on
                        case "x": state.xtrace = on
                        case "f": state.noglob = on
                        case "o":
                            if i + 1 < args.count, args[i + 1] == "pipefail" { state.pipefail = on; i += 1 }
                        default: break
                        }
                    }
                    i += 1; continue
                }
                state.positional = Array(args[i...])
                return 0
            }
            return 0

        case "shift":
            let n = Int(args.first ?? "1") ?? 1
            guard n <= state.positional.count else { return 1 }
            state.positional.removeFirst(n)
            return 0

        case "exit":
            let code = args.first.flatMap { Int32($0) } ?? state.lastStatus
            throw ShellControl.exit(code & 0xFF)

        case "return":
            throw ShellControl.returned(args.first.flatMap { Int32($0) } ?? state.lastStatus)

        case "break":
            throw ShellControl.breakLoop(Int(args.first ?? "1") ?? 1)

        case "continue":
            throw ShellControl.continueLoop(Int(args.first ?? "1") ?? 1)

        case "test", "[":
            var a = args
            if name == "[" {
                guard a.last == "]" else { err("']' mancante"); return 2 }
                a.removeLast()
            }
            do { return try ShellTest.evaluate(a.map { ($0, false) }, extended: false, interp: sh) ? 0 : 1 }
            catch { err(error.localizedDescription); return 2 }

        case "read":
            var raw = false
            var prompt: String? = nil
            var delim: Character = "\n"
            var names: [String] = []
            var i = 0
            while i < args.count {
                let a = args[i]
                switch a {
                case "-r": raw = true
                case "-p": if i + 1 < args.count { prompt = args[i + 1]; i += 1 }
                case "-d": if i + 1 < args.count { delim = args[i + 1].first ?? "\0"; i += 1 }
                case "-s", "-e": break
                case "-t", "-n", "-N", "-u": i += 1
                default: names.append(a)
                }
                i += 1
            }
            if let p = prompt { io.stderr.write(p) }
            guard let firstLine = io.stdin.readLine(delimiter: delim) else {
                for n in names { state.setVar(n, "") }
                return 1
            }
            var line = firstLine.0
            if !raw {
                while line.hasSuffix("\\"), let more = io.stdin.readLine(delimiter: delim) {
                    line = String(line.dropLast()) + more.0
                }
                line = line.replacingOccurrences(of: "\\", with: "")
            }
            if names.isEmpty { state.setVar("REPLY", line); return 0 }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            for (idx, n) in names.enumerated() {
                if idx == names.count - 1 {
                    let restFields = idx < fields.count ? fields[idx...].joined(separator: " ") : ""
                    state.setVar(n, restFields)
                } else {
                    state.setVar(n, idx < fields.count ? fields[idx] : "")
                }
            }
            return 0

        case "source", ".":
            guard let file = args.first else { err("nome file richiesto"); return 2 }
            return try await sh.runScriptFile(path: file, args: Array(args.dropFirst()), io: io, sourceInCurrent: true)

        case "eval":
            let src = args.joined(separator: " ")
            let node = try ShellParser.parse(src)
            return try await sh.execute(node, io, cond: false)

        case "exec":
            if args.isEmpty { return 0 }
            let st = try await sh.invoke(args, io)
            throw ShellControl.exit(st)

        case "command":
            var a = args
            if a.first == "-v" || a.first == "-V" {
                a.removeFirst()
                var found = false
                for n in a {
                    if state.functions[n] != nil || implemented.contains(n) {
                        io.stdout.write((implemented.contains(n) && !["cd", "export", "set", "echo"].contains(n) ? "/usr/bin/\(n)" : n) + "\n")
                        found = true
                    }
                }
                return found ? 0 : 1
            }
            if a.first == "-p" { a.removeFirst() }
            if a.isEmpty { return 0 }
            return try await sh.invoke(a, io, skipFunctions: true)

        case "type":
            var st: Int32 = 0
            for n in args where !n.hasPrefix("-") {
                if state.functions[n] != nil { io.stdout.write("\(n) is a function\n") }
                else if implemented.contains(n) { io.stdout.write("\(n) is /usr/bin/\(n)\n") }
                else { io.stderr.write("type: \(n): non trovato\n"); st = 1 }
            }
            return st

        case "which":
            var st: Int32 = 0
            for n in args where !n.hasPrefix("-") {
                if implemented.contains(n) { io.stdout.write("/usr/bin/\(n)\n") } else { st = 1 }
            }
            return st

        case "sleep":
            var total: Double = 0
            for a in args {
                var s = a
                var mult = 1.0
                if s.hasSuffix("s") { s.removeLast() }
                else if s.hasSuffix("m") { s.removeLast(); mult = 60 }
                else if s.hasSuffix("h") { s.removeLast(); mult = 3600 }
                total += (Double(s) ?? 0) * mult
            }
            var remaining = total
            while remaining > 0 {
                try sh.host.checkInterrupt()
                let chunk = min(remaining, 0.5)
                try? await Task.sleep(nanoseconds: UInt64(chunk * 1_000_000_000))
                remaining -= chunk
            }
            return 0

        case "env", "printenv":
            var a = args
            var overrides: [(String, String)] = []
            while let f = a.first, f.contains("="), !f.hasPrefix("=") {
                let (n, v, _) = splitAssignment(f)
                overrides.append((n, v ?? ""))
                a.removeFirst()
            }
            if a.first == "-i" { a.removeFirst() }
            if name == "env" && !a.isEmpty {
                var saved: [(String, String?)] = []
                for (n, v) in overrides { saved.append((n, state.vars[n])); state.setVar(n, v, export: true) }
                defer { for (n, v) in saved { if let v = v { state.vars[n] = v } else { state.vars.removeValue(forKey: n) } } }
                return try await sh.invoke(a, io)
            }
            if name == "printenv" && !a.isEmpty {
                var st: Int32 = 0
                for n in a { if let v = state.environment[n] { io.stdout.write(v + "\n") } else { st = 1 } }
                return st
            }
            var env = state.environment
            for (n, v) in overrides { env[n] = v }
            for k in env.keys.sorted() { io.stdout.write("\(k)=\(env[k]!)\n") }
            return 0

        case "cat":
            var number = false
            var files: [String] = []
            for a in args {
                if a == "-n" { number = true } else if a != "-" && a.hasPrefix("-") && a.count > 1 { continue } else { files.append(a) }
            }
            guard let text = readInputs(files, io, sh, err) else { return 1 }
            if number {
                var n = 0
                var out = ""
                for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropLast(text.hasSuffix("\n") ? 1 : 0) {
                    n += 1
                    out += String(format: "%6d\t", n) + line + "\n"
                }
                io.stdout.write(out)
            } else {
                io.stdout.write(text)
            }
            return 0

        case "ls":
            return FileCommands.ls(args, io, sh)
        case "mkdir":
            return FileCommands.mkdir(args, io, sh)
        case "rmdir":
            for a in args where !a.hasPrefix("-") {
                do { try FileManager.default.removeItem(at: sh.resolve(a)) } catch { err("\(a): \(error.localizedDescription)"); return 1 }
            }
            return 0
        case "rm":
            return FileCommands.rm(args, io, sh)
        case "cp":
            return FileCommands.cp(args, io, sh, move: false)
        case "mv":
            return FileCommands.cp(args, io, sh, move: true)
        case "touch":
            for a in args where !a.hasPrefix("-") {
                let u = sh.resolve(a)
                if FileManager.default.fileExists(atPath: u.path) {
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path)
                } else {
                    try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                    FileManager.default.createFile(atPath: u.path, contents: Data())
                }
            }
            return 0
        case "ln":
            return FileCommands.ln(args, io, sh)
        case "chmod":
            return FileCommands.chmod(args, io, sh)
        case "chown":
            return 0
        case "stat":
            return FileCommands.stat(args, io, sh)
        case "du":
            return FileCommands.du(args, io, sh)
        case "df":
            io.stdout.write("Filesystem     Size  Used Avail Use% Mounted on\n/dev/disk1s1   100G   50G   50G  50% /\n")
            return 0
        case "file":
            for a in args where !a.hasPrefix("-") {
                let u = sh.resolve(a)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) {
                    io.stdout.write("\(a): \(isDir.boolValue ? "directory" : (isText(u) ? "ASCII text" : "data"))\n")
                } else { io.stdout.write("\(a): cannot open\n") }
            }
            return 0
        case "find":
            let (st, script) = FileCommands.find(args, io, sh)
            if let script = script, !script.isEmpty {
                return try await sh.execute(try ShellParser.parse(script), io, cond: true)
            }
            return st

        case "head", "tail":
            return TextCommands.headTail(name, args, io, sh)
        case "wc":
            return TextCommands.wc(args, io, sh)
        case "grep", "egrep", "fgrep":
            return TextCommands.grep(name, args, io, sh)
        case "sed":
            return TextCommands.sed(args, io, sh)
        case "awk":
            return TextCommands.awk(args, io, sh)
        case "cut":
            return TextCommands.cut(args, io, sh)
        case "tr":
            return TextCommands.tr(args, io, sh)
        case "sort":
            return TextCommands.sort(args, io, sh)
        case "uniq":
            return TextCommands.uniq(args, io, sh)
        case "rev":
            guard let text = readInputs(args, io, sh, err) else { return 1 }
            io.stdout.write(lines(text).map { String($0.reversed()) }.joined(separator: "\n") + (text.isEmpty ? "" : "\n"))
            return 0
        case "nl":
            guard let text = readInputs(args.filter { !$0.hasPrefix("-") }, io, sh, err) else { return 1 }
            var n = 0
            io.stdout.write(lines(text).map { l -> String in
                if l.isEmpty { return "" }
                n += 1
                return String(format: "%6d\t", n) + l
            }.joined(separator: "\n") + "\n")
            return 0
        case "fold":
            var width = 80
            var files: [String] = []
            var i = 0
            while i < args.count {
                if args[i] == "-w", i + 1 < args.count { width = Int(args[i + 1]) ?? 80; i += 2; continue }
                if args[i].hasPrefix("-w") { width = Int(args[i].dropFirst(2)) ?? 80; i += 1; continue }
                files.append(args[i]); i += 1
            }
            guard let text = readInputs(files, io, sh, err) else { return 1 }
            var out = ""
            for l in lines(text) {
                var chars = Array(l)
                while chars.count > width { out += String(chars[0..<width]) + "\n"; chars.removeFirst(width) }
                out += String(chars) + "\n"
            }
            io.stdout.write(out)
            return 0
        case "paste":
            var sep = "\t"
            var files: [String] = []
            var serial = false
            var i = 0
            while i < args.count {
                if args[i] == "-d", i + 1 < args.count { sep = args[i + 1]; i += 2; continue }
                if args[i].hasPrefix("-d") { sep = String(args[i].dropFirst(2)); i += 1; continue }
                if args[i] == "-s" { serial = true; i += 1; continue }
                files.append(args[i]); i += 1
            }
            if serial || files.count <= 1 {
                guard let text = readInputs(files, io, sh, err) else { return 1 }
                io.stdout.write(lines(text).joined(separator: sep) + "\n")
                return 0
            }
            let cols = files.map { f -> [String] in lines((try? String(contentsOf: sh.resolve(f), encoding: .utf8)) ?? "") }
            let rows = cols.map { $0.count }.max() ?? 0
            for r in 0..<rows { io.stdout.write(cols.map { r < $0.count ? $0[r] : "" }.joined(separator: sep) + "\n") }
            return 0
        case "diff", "cmp", "comm":
            let files = args.filter { !$0.hasPrefix("-") }
            guard files.count == 2 else { err("servono due file"); return 2 }
            let a = (try? String(contentsOf: sh.resolve(files[0]), encoding: .utf8)) ?? ""
            let b = (try? String(contentsOf: sh.resolve(files[1]), encoding: .utf8)) ?? ""
            if a == b { return 0 }
            if name == "comm" {
                let la = Set(lines(a)), lb = Set(lines(b))
                for l in la.union(lb).sorted() {
                    if la.contains(l) && lb.contains(l) { io.stdout.write("\t\t\(l)\n") }
                    else if la.contains(l) { io.stdout.write("\(l)\n") }
                    else { io.stdout.write("\t\(l)\n") }
                }
                return 0
            }
            if !args.contains("-q") && !args.contains("-s") {
                let la = lines(a), lb = lines(b)
                for i in 0..<max(la.count, lb.count) {
                    let x = i < la.count ? la[i] : nil, y = i < lb.count ? lb[i] : nil
                    if x != y {
                        if let x = x { io.stdout.write("< \(x)\n") }
                        if let y = y { io.stdout.write("> \(y)\n") }
                    }
                }
            }
            return 1

        case "tee":
            var append = false
            var files: [String] = []
            for a in args { if a == "-a" { append = true } else if !a.hasPrefix("-") { files.append(a) } }
            let text = io.stdin.readAll()
            io.stdout.write(text)
            for f in files {
                let sink = FileSink(url: sh.resolve(f), append: append)
                sink.write(text)
            }
            return 0

        case "basename":
            var a = args.filter { $0 != "--" }
            if a.first == "-a" { a.removeFirst(); for p in a { io.stdout.write((p as NSString).lastPathComponent + "\n") }; return 0 }
            guard let p = a.first else { err("operando mancante"); return 1 }
            var base = p == "/" ? "/" : (p.hasSuffix("/") ? String(p.dropLast()) : p)
            base = (base as NSString).lastPathComponent
            if a.count > 1, base.hasSuffix(a[1]), base != a[1] { base = String(base.dropLast(a[1].count)) }
            io.stdout.write(base + "\n")
            return 0

        case "dirname":
            for p in args where !p.hasPrefix("-") {
                var d = (p as NSString).deletingLastPathComponent
                if d.isEmpty { d = "." }
                io.stdout.write(d + "\n")
            }
            return 0

        case "realpath", "readlink":
            for p in args where !p.hasPrefix("-") {
                let u = sh.resolve(p)
                if name == "readlink" && !args.contains("-f") && !args.contains("-e") && !args.contains("-m") {
                    if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: u.path) { io.stdout.write(dest + "\n") } else { return 1 }
                } else {
                    io.stdout.write(u.resolvingSymlinksInPath().path + "\n")
                }
            }
            return 0

        case "date":
            return DateCommand.run(args, io)

        case "seq":
            let nums = args.filter { Double($0) != nil }.compactMap { Double($0) }
            var first = 1.0, step = 1.0, last = 1.0
            switch nums.count {
            case 1: last = nums[0]
            case 2: first = nums[0]; last = nums[1]
            case 3: first = nums[0]; step = nums[1]; last = nums[2]
            default: err("operando mancante"); return 1
            }
            var sep = "\n"
            if let i = args.firstIndex(of: "-s"), i + 1 < args.count { sep = args[i + 1] }
            guard step != 0 else { return 1 }
            var out: [String] = []
            var v = first
            while (step > 0 ? v <= last + 1e-9 : v >= last - 1e-9) && out.count < 1_000_000 {
                out.append(JSONValue.formatNumber(v)); v += step
            }
            io.stdout.write(out.joined(separator: sep) + (out.isEmpty ? "" : "\n"))
            return 0

        case "yes":
            let word = args.isEmpty ? "y" : args.joined(separator: " ")
            io.stdout.write(Array(repeating: word, count: 1000).joined(separator: "\n") + "\n")
            return 0

        case "xargs":
            var a = args
            var replace: String? = nil
            var maxArgs: Int? = nil
            var nullSep = false
            while let f = a.first, f.hasPrefix("-") {
                a.removeFirst()
                if f == "-I", let r = a.first { replace = r; a.removeFirst() }
                else if f.hasPrefix("-I") { replace = String(f.dropFirst(2)) }
                else if f == "-n", let n = a.first { maxArgs = Int(n); a.removeFirst() }
                else if f == "-0" { nullSep = true }
                else if f == "-r" || f == "--no-run-if-empty" || f == "-t" { continue }
            }
            if a.isEmpty { a = ["echo"] }
            let input = io.stdin.readAll()
            let items: [String]
            if nullSep { items = input.split(separator: "\0").map(String.init) }
            else if replace != nil { items = lines(input).filter { !$0.isEmpty } }
            else { items = input.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init) }
            if items.isEmpty { return 0 }
            var st: Int32 = 0
            if let r = replace {
                for item in items {
                    let cmd = a.map { $0.replacingOccurrences(of: r, with: item) }
                    let s = try await sh.invoke(cmd, ShIO(stdin: .empty, stdout: io.stdout, stderr: io.stderr))
                    if s != 0 { st = 123 }
                }
                return st
            }
            let chunkSize = maxArgs ?? items.count
            var idx = 0
            while idx < items.count {
                let chunk = Array(items[idx..<min(idx + chunkSize, items.count)])
                let s = try await sh.invoke(a + chunk, ShIO(stdin: .empty, stdout: io.stdout, stderr: io.stderr))
                if s != 0 { st = 123 }
                idx += chunkSize
            }
            return st

        case "uname":
            let os = sh.host.runnerOS
            let kernel = os == "macOS" ? "Darwin" : (os == "Windows" ? "MINGW64_NT" : "Linux")
            let machine = sh.host.runnerArch == "ARM64" ? (os == "macOS" ? "arm64" : "aarch64") : "x86_64"
            let release = os == "macOS" ? "25.0.0" : "6.8.0-azure"
            if args.contains("-a") {
                io.stdout.write("\(kernel) ActionsRunner-iOS \(release) #1 SMP \(machine) \(machine) \(machine) GNU/\(kernel)\n")
            } else if args.contains("-m") || args.contains("-p") { io.stdout.write(machine + "\n") }
            else if args.contains("-r") { io.stdout.write(release + "\n") }
            else if args.contains("-n") { io.stdout.write("ActionsRunner-iOS\n") }
            else { io.stdout.write(kernel + "\n") }
            return 0
        case "arch":
            io.stdout.write((sh.host.runnerArch == "ARM64" ? "arm64" : "x86_64") + "\n")
            return 0
        case "sw_vers":
            guard sh.host.runnerOS == "macOS" else { io.stderr.write(notFoundMessage(name)); return 127 }
            io.stdout.write("ProductName:\t\tmacOS\nProductVersion:\t\t26.0\nBuildVersion:\t\t25A354\n")
            return 0
        case "whoami":
            io.stdout.write("runner\n"); return 0
        case "hostname":
            io.stdout.write("ActionsRunner-iOS\n"); return 0
        case "id":
            if args.contains("-u") { io.stdout.write("1001\n") }
            else if args.contains("-g") { io.stdout.write("118\n") }
            else if args.contains("-un") || args.contains("-nu") { io.stdout.write("runner\n") }
            else { io.stdout.write("uid=1001(runner) gid=118(docker) groups=118(docker)\n") }
            return 0
        case "nproc":
            io.stdout.write("\(ProcessInfo.processInfo.activeProcessorCount)\n"); return 0
        case "ps":
            io.stdout.write("  PID TTY          TIME CMD\n 4242 ?        00:00:00 bash\n"); return 0
        case "kill":
            return 0
        case "tput":
            if args.first == "cols" { io.stdout.write("120\n") } else if args.first == "lines" { io.stdout.write("40\n") }
            return 0

        case "base64":
            let decode = args.contains("-d") || args.contains("--decode") || args.contains("-D")
            let files = args.filter { !$0.hasPrefix("-") }
            var data: Data
            if let f = files.first {
                guard let d = try? Data(contentsOf: sh.resolve(f)) else { err("\(f): file non trovato"); return 1 }
                data = d
            } else {
                data = Data(io.stdin.readAll().utf8)
            }
            if decode {
                let clean = String(decoding: data, as: UTF8.self).filter { !$0.isWhitespace }
                var padded = clean
                while padded.count % 4 != 0 { padded += "=" }
                guard let d = Data(base64Encoded: padded) else { err("input non valido"); return 1 }
                io.stdout.write(String(decoding: d, as: UTF8.self))
            } else {
                let wrap = args.contains("-w0") || args.contains("-w") ? 0 : 76
                var s = data.base64EncodedString()
                if wrap > 0 {
                    var chunks: [String] = []
                    var chars = Array(s)
                    while chars.count > wrap { chunks.append(String(chars[0..<wrap])); chars.removeFirst(wrap) }
                    chunks.append(String(chars))
                    s = chunks.joined(separator: "\n")
                }
                io.stdout.write(s + "\n")
            }
            return 0

        case "sha256sum", "sha1sum", "md5sum", "shasum", "md5":
            var algo = name
            if name == "shasum" {
                algo = "sha1sum"
                if let i = args.firstIndex(of: "-a"), i + 1 < args.count { algo = args[i + 1] == "256" ? "sha256sum" : (args[i + 1] == "512" ? "sha512" : "sha1sum") }
            }
            var files = args.filter { !$0.hasPrefix("-") && $0 != "256" && $0 != "1" && $0 != "512" }
            if files.isEmpty { files = ["-"] }
            for f in files {
                let data: Data
                if f == "-" { data = Data(io.stdin.readAll().utf8) }
                else {
                    guard let d = try? Data(contentsOf: sh.resolve(f)) else { err("\(f): file non trovato"); return 1 }
                    data = d
                }
                let hex: String
                switch algo {
                case "sha256sum": hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                case "sha512": hex = SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
                case "md5sum", "md5": hex = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
                default: hex = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
                }
                if name == "md5" { io.stdout.write(f == "-" ? hex + "\n" : "MD5 (\(f)) = \(hex)\n") }
                else { io.stdout.write("\(hex)  \(f)\n") }
            }
            return 0

        case "zip":
            return FileCommands.zip(args, io, sh)
        case "unzip":
            return FileCommands.unzip(args, io, sh)

        case "curl", "wget":
            return await NetCommands.fetch(name, args, io, sh)

        case "jq":
            return JQ.run(args, io, sh)

        case "git":
            return GitEmulation.run(args, io, sh)

        case "trap":
            if args.count >= 2, args[1...].contains(where: { $0 == "EXIT" || $0 == "0" }) { state.exitTrap = args[0] }
            return 0

        case "mktemp":
            let dir = args.contains("-d")
            let base = URL(fileURLWithPath: state.vars["RUNNER_TEMP"] ?? sh.host.tempDir)
            let u = base.appendingPathComponent("tmp.\(UUID().uuidString.prefix(10))")
            if dir { try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) }
            else { FileManager.default.createFile(atPath: u.path, contents: Data()) }
            io.stdout.write(u.path + "\n")
            return 0

        case "bash", "sh":
            var a = args
            let child = state.childProcess()
            while let f = a.first, f.hasPrefix("-") || f.hasPrefix("+") {
                a.removeFirst()
                if f.hasPrefix("--") { continue }   // --noprofile, --norc, --login...
                if f.contains("c") {
                    if f.contains("e") { child.errexit = true }
                    guard let script = a.first else { err("-c: richiede un argomento"); return 2 }
                    child.positional = Array(a.dropFirst(2))
                    let sub = ShellInterpreter(state: child, host: sh.host)
                    return await sub.run(script: script, io: io)
                }
                if f.contains("e") { child.errexit = true }
                if f.contains("x") { child.xtrace = true }
                if f.contains("u") { child.nounset = true }
                if f.hasSuffix("o"), a.first == "pipefail" { child.pipefail = true; a.removeFirst() }
            }
            if let script = a.first {
                return try await sh.runScriptFile(path: script, args: Array(a.dropFirst()), io: io)
            }
            let text = io.stdin.readAll()
            let sub = ShellInterpreter(state: child, host: sh.host)
            return await sub.run(script: text, io: io)

        case "let":
            var last: Int64 = 0
            for a in args { last = try sh.arith(a) }
            return last != 0 ? 0 : 1

        case "expr":
            return Expr_.run(args, io)

        case "getopts":
            guard args.count >= 2 else { return 2 }
            let spec = args[0], varName = args[1]
            let params = args.count > 2 ? Array(args[2...]) : state.positional
            var optind = Int(state.vars["OPTIND"] ?? "1") ?? 1
            guard optind - 1 < params.count else { state.setVar(varName, "?"); return 1 }
            let cur = params[optind - 1]
            guard cur.hasPrefix("-"), cur != "-", cur != "--", cur.count >= 2 else { state.setVar(varName, "?"); return 1 }
            let opt = cur[cur.index(after: cur.startIndex)]
            guard let specIdx = spec.firstIndex(of: opt) else {
                state.setVar(varName, "?"); optind += 1; state.setVar("OPTIND", String(optind)); return 0
            }
            state.setVar(varName, String(opt))
            let needsArg = spec.index(after: specIdx) < spec.endIndex && spec[spec.index(after: specIdx)] == ":"
            if needsArg {
                if cur.count > 2 { state.setVar("OPTARG", String(cur.dropFirst(2))); optind += 1 }
                else if optind < params.count { state.setVar("OPTARG", params[optind]); optind += 2 }
                else { state.setVar(varName, "?"); optind += 1 }
            } else { optind += 1 }
            state.setVar("OPTIND", String(optind))
            return 0

        case "timeout", "nohup", "time":
            var a = args
            if name == "timeout" {
                while let f = a.first, f.hasPrefix("-") { a.removeFirst() }
                if !a.isEmpty { a.removeFirst() }
            }
            if a.isEmpty { return 0 }
            return try await sh.invoke(a, io)

        default:
            return nil
        }
    }

    // MARK: Utilità

    static func splitAssignment(_ s: String) -> (String, String?, Bool) {
        guard let eq = s.firstIndex(of: "=") else { return (s, nil, false) }
        var name = String(s[..<eq])
        var append = false
        if name.hasSuffix("+") { name.removeLast(); append = true }
        return (name, String(s[s.index(after: eq)...]), append)
    }

    static func processEscapes(_ s: String) -> (String, Bool) {
        var out = ""
        let c = Array(s)
        var i = 0
        while i < c.count {
            if c[i] == "\\", i + 1 < c.count {
                switch c[i + 1] {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "\\": out.append("\\")
                case "a": out.append("\u{07}")
                case "b": out.append("\u{08}")
                case "e", "E": out.append("\u{1B}")
                case "f": out.append("\u{0C}")
                case "v": out.append("\u{0B}")
                case "c": return (out, true)
                case "0":
                    var j = i + 2
                    var oct = ""
                    while j < c.count, oct.count < 3, ("0"..."7").contains(c[j]) { oct.append(c[j]); j += 1 }
                    if let v = UInt32(oct.isEmpty ? "0" : oct, radix: 8), let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
                    i = j
                    continue
                case "x":
                    var j = i + 2
                    var hex = ""
                    while j < c.count, hex.count < 2, c[j].isHexDigit { hex.append(c[j]); j += 1 }
                    if let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
                    i = j
                    continue
                case "u":
                    var j = i + 2
                    var hex = ""
                    while j < c.count, hex.count < 4, c[j].isHexDigit { hex.append(c[j]); j += 1 }
                    if let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
                    i = j
                    continue
                default:
                    out.append("\\"); out.append(c[i + 1])
                }
                i += 2
            } else {
                out.append(c[i]); i += 1
            }
        }
        return (out, false)
    }

    /// Legge i file indicati (o stdin se vuoto / "-").
    static func readInputs(_ files: [String], _ io: ShIO, _ sh: ShellInterpreter, _ err: (String) -> Void) -> String? {
        if files.isEmpty { return io.stdin.readAll() }
        var out = ""
        for f in files {
            if f == "-" { out += io.stdin.readAll(); continue }
            let u = sh.resolve(f)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { err("\(f): File o directory non esistente"); return nil }
            if isDir.boolValue { err("\(f): È una directory"); return nil }
            guard let data = try? Data(contentsOf: u) else { err("\(f): impossibile leggere"); return nil }
            out += String(decoding: data, as: UTF8.self)
        }
        return out
    }

    static func lines(_ text: String) -> [String] {
        var parts = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { parts.removeLast() }
        if text.isEmpty { return [] }
        return parts
    }

    static func isText(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 4096)) ?? Data()
        return !data.contains(0) && String(data: data, encoding: .utf8) != nil
    }
}

// MARK: - printf

enum Printf {
    static func format(_ fmt: String, _ args: [String]) -> String {
        var out = ""
        var argIndex = 0
        var consumedAny = false
        repeat {
            consumedAny = false
            let c = Array(fmt)
            var i = 0
            while i < c.count {
                let ch = c[i]
                if ch == "\\" {
                    let (s, _) = ShellBuiltins.processEscapes(String(c[i...min(i + 1, c.count - 1)]))
                    if i + 1 < c.count, c[i + 1] == "0" || c[i + 1] == "x" {
                        var j = i + 2
                        while j < c.count, j < i + 5, c[j].isHexDigit { j += 1 }
                        out += ShellBuiltins.processEscapes(String(c[i..<j])).0
                        i = j
                        continue
                    }
                    out += s
                    i += 2
                    continue
                }
                if ch == "%" {
                    if i + 1 < c.count, c[i + 1] == "%" { out.append("%"); i += 2; continue }
                    var j = i + 1
                    var flags = ""
                    while j < c.count, "-+ 0#".contains(c[j]) { flags.append(c[j]); j += 1 }
                    var width = ""
                    while j < c.count, c[j].isNumber { width.append(c[j]); j += 1 }
                    var precision: String? = nil
                    if j < c.count, c[j] == "." {
                        j += 1
                        var p = ""
                        while j < c.count, c[j].isNumber { p.append(c[j]); j += 1 }
                        precision = p
                    }
                    guard j < c.count else { out += String(c[i...]); break }
                    let conv = c[j]
                    let arg: String? = argIndex < args.count ? args[argIndex] : nil
                    if arg != nil { argIndex += 1; consumedAny = true }
                    let a = arg ?? ""
                    var piece: String
                    switch conv {
                    case "s", "q":
                        piece = a
                        if let p = precision, let n = Int(p) { piece = String(piece.prefix(n)) }
                    case "b":
                        piece = ShellBuiltins.processEscapes(a).0
                    case "c":
                        piece = a.first.map { String($0) } ?? ""
                    case "d", "i":
                        let v = Int64(a.trimmingCharacters(in: .whitespaces)) ?? Int64(Double(a) ?? 0)
                        piece = String(format: "%" + flags + width + "lld", v)
                        out += piece; i = j + 1; continue
                    case "u":
                        piece = String(UInt64(max(0, Int64(a) ?? 0)))
                    case "x", "X", "o":
                        let v = Int64(a) ?? 0
                        piece = String(format: "%" + flags + width + "ll" + String(conv), v)
                        out += piece; i = j + 1; continue
                    case "f", "F", "e", "E", "g", "G":
                        let v = Double(a) ?? 0
                        let spec = "%" + flags + width + (precision.map { "." + $0 } ?? "") + String(conv)
                        out += String(format: spec, v); i = j + 1; continue
                    default:
                        piece = String(c[i...j])
                    }
                    if let w = Int(width), piece.count < w {
                        let pad = String(repeating: " ", count: w - piece.count)
                        piece = flags.contains("-") ? piece + pad : pad + piece
                    }
                    out += piece
                    i = j + 1
                    continue
                }
                out.append(ch)
                i += 1
            }
        } while consumedAny && argIndex < args.count
        return out
    }
}

// MARK: - expr

enum Expr_ {
    static func run(_ args: [String], _ io: ShIO) -> Int32 {
        if args.count == 3 {
            let a = args[0], op = args[1], b = args[2]
            if let x = Int64(a), let y = Int64(b) {
                var r: Int64 = 0
                switch op {
                case "+": r = x + y
                case "-": r = x - y
                case "*": r = x * y
                case "/": guard y != 0 else { return 2 }; r = x / y
                case "%": guard y != 0 else { return 2 }; r = x % y
                case "<": r = x < y ? 1 : 0
                case "<=": r = x <= y ? 1 : 0
                case ">": r = x > y ? 1 : 0
                case ">=": r = x >= y ? 1 : 0
                case "=": r = x == y ? 1 : 0
                case "!=": r = x != y ? 1 : 0
                default: return 2
                }
                io.stdout.write("\(r)\n")
                return r == 0 ? 1 : 0
            }
            if op == "=" || op == "!=" {
                let eq = (a == b) == (op == "=")
                io.stdout.write(eq ? "1\n" : "0\n")
                return eq ? 0 : 1
            }
            if op == ":" {
                if let re = try? NSRegularExpression(pattern: "^" + b),
                   let m = re.firstMatch(in: a, range: NSRange(a.startIndex..., in: a)) {
                    if m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: a) { io.stdout.write(String(a[r]) + "\n") }
                    else { io.stdout.write("\(m.range.length)\n") }
                    return 0
                }
                io.stdout.write("0\n")
                return 1
            }
        }
        if args.count == 2, args[0] == "length" { io.stdout.write("\(args[1].count)\n"); return 0 }
        if args.count == 1 { io.stdout.write(args[0] + "\n"); return args[0].isEmpty || args[0] == "0" ? 1 : 0 }
        io.stderr.write("expr: espressione non supportata\n")
        return 2
    }
}
