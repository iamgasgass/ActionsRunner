import Foundation

/// Informazioni dall'ambiente del runner verso l'interprete.
final class ShellHost {
    var runnerOS = "Linux"
    var runnerArch = "ARM64"
    var tempDir = NSTemporaryDirectory()
    var homeDir = NSHomeDirectory()
    var gitSHA = String(repeating: "0", count: 40)
    var gitRef = "refs/heads/main"
    var deadline: Date?
    var isCancelled: () -> Bool = { false }
    var debugTrace = false

    func checkInterrupt() throws {
        if isCancelled() || Task.isCancelled { throw ShellControl.exit(130) }
        if let d = deadline, Date() > d { throw ShellRuntimeError(message: "timeout dello step superato") }
    }
}

final class ShellInterpreter {
    let state: ShellState
    let host: ShellHost

    init(state: ShellState, host: ShellHost) {
        self.state = state
        self.host = host
    }

    // MARK: Entry point

    /// Esegue uno script completo; restituisce l'exit code.
    func run(script: String, io: ShIO) async -> Int32 {
        let node: ShNode
        do { node = try ShellParser.parse(script) } catch {
            io.stderr.write("\(state.scriptName): \(error.localizedDescription)\n")
            return 2
        }
        var status: Int32 = 0
        do {
            status = try await execute(node, io, cond: false)
        } catch ShellControl.exit(let code) {
            status = code
        } catch ShellControl.returned(let code) {
            status = code
        } catch ShellControl.breakLoop, ShellControl.continueLoop {
            status = 0
        } catch {
            io.stderr.write("\(state.scriptName): \(error.localizedDescription)\n")
            status = 1
        }
        if let trap = state.exitTrap {
            state.exitTrap = nil
            state.lastStatus = status
            _ = await run(script: trap, io: io)
        }
        return status
    }

    // MARK: Esecuzione

    func execute(_ node: ShNode, _ io: ShIO, cond: Bool) async throws -> Int32 {
        try host.checkInterrupt()
        switch node {
        case .empty:
            return state.lastStatus

        case .simple(let cmd):
            let st = try await executeSimple(cmd, io)
            return try finish(st, cond: cond)

        case .pipeline(let cmds, let negated):
            var input = io.stdin
            var statuses: [Int32] = []
            for (i, c) in cmds.enumerated() {
                let isLast = i == cmds.count - 1
                if isLast {
                    let st = try await executeInSubshellIfNeeded(c, ShIO(stdin: input, stdout: io.stdout, stderr: io.stderr), multi: cmds.count > 1)
                    statuses.append(st)
                } else {
                    let buffer = BufferSink()
                    let st = try await executeInSubshellIfNeeded(c, ShIO(stdin: input, stdout: buffer, stderr: io.stderr), multi: true)
                    statuses.append(st)
                    input = InputSource(buffer.text)
                }
            }
            var st = statuses.last ?? 0
            if state.pipefail, let failed = statuses.last(where: { $0 != 0 }) { st = failed }
            if negated { st = st == 0 ? 1 : 0; state.lastStatus = st; return st }
            return try finish(st, cond: cond)

        case .andOr(let first, let rest):
            var st = try await execute(first, io, cond: true)
            for (i, part) in rest.enumerated() {
                let isLast = i == rest.count - 1
                if part.op == "&&" && st != 0 { continue }
                if part.op == "||" && st == 0 { continue }
                st = try await execute(part.node, io, cond: isLast ? cond : true)
            }
            state.lastStatus = st
            return st

        case .sequence(let items):
            var st: Int32 = 0
            for item in items { st = try await execute(item, io, cond: cond) }
            return st

        case .ifClause(let branches, let elseBody):
            for b in branches {
                let c = try await execute(b.condition, io, cond: true)
                if c == 0 { return try await execute(b.body, io, cond: cond) }
            }
            if let e = elseBody { return try await execute(e, io, cond: cond) }
            state.lastStatus = 0
            return 0

        case .forClause(let name, let words, let body):
            var items: [String] = []
            if let words = words {
                for w in words { items.append(contentsOf: try await expandWord(w)) }
            } else {
                items = state.positional
            }
            var st: Int32 = 0
            loop: for item in items {
                state.setVar(name, item)
                do { st = try await execute(body, io, cond: cond) }
                catch ShellControl.breakLoop(let n) { if n > 1 { throw ShellControl.breakLoop(n - 1) }; break loop }
                catch ShellControl.continueLoop(let n) { if n > 1 { throw ShellControl.continueLoop(n - 1) }; continue loop }
            }
            return st

        case .cFor(let initExpr, let condExpr, let stepExpr, let body):
            if !initExpr.trimmingCharacters(in: .whitespaces).isEmpty { _ = try arith(initExpr) }
            var st: Int32 = 0
            loop: while true {
                try host.checkInterrupt()
                if !condExpr.trimmingCharacters(in: .whitespaces).isEmpty, try arith(condExpr) == 0 { break }
                do { st = try await execute(body, io, cond: cond) }
                catch ShellControl.breakLoop(let n) { if n > 1 { throw ShellControl.breakLoop(n - 1) }; break loop }
                catch ShellControl.continueLoop(let n) { if n > 1 { throw ShellControl.continueLoop(n - 1) } }
                if !stepExpr.trimmingCharacters(in: .whitespaces).isEmpty { _ = try arith(stepExpr) }
            }
            return st

        case .whileClause(let condNode, let body, let until):
            var st: Int32 = 0
            var iterations = 0
            loop: while true {
                try host.checkInterrupt()
                iterations += 1
                if iterations > 1_000_000 { throw ShellRuntimeError(message: "ciclo while troppo lungo (>1.000.000 iterazioni)") }
                let c = try await execute(condNode, io, cond: true)
                if until ? c == 0 : c != 0 { break }
                do { st = try await execute(body, io, cond: cond) }
                catch ShellControl.breakLoop(let n) { if n > 1 { throw ShellControl.breakLoop(n - 1) }; break loop }
                catch ShellControl.continueLoop(let n) { if n > 1 { throw ShellControl.continueLoop(n - 1) }; continue loop }
            }
            state.lastStatus = st
            return st

        case .caseClause(let word, let items):
            let value = try await expandWordNoSplit(word)
            var matchedPrevious = false
            for item in items {
                var matched = matchedPrevious
                if !matched {
                    for p in item.patterns {
                        let pat = try await expandPattern(p)
                        if ShellPattern.matches(value, pat) { matched = true; break }
                    }
                }
                if matched {
                    let st = try await execute(item.body, io, cond: cond)
                    if item.fallthroughMode == ";&" { matchedPrevious = true; continue }
                    if item.fallthroughMode == ";;&" { matchedPrevious = false; continue }
                    return st
                }
            }
            state.lastStatus = 0
            return 0

        case .group(let body, let subshell):
            if subshell {
                let sub = ShellInterpreter(state: state.copy(), host: host)
                do { return try await sub.execute(body, io, cond: cond) }
                catch ShellControl.exit(let code) { return code }
            }
            return try await execute(body, io, cond: cond)

        case .arith(let expr):
            let v = try arith(try await expandArithText(expr))
            let st: Int32 = v != 0 ? 0 : 1
            state.lastStatus = st
            return try finish(st, cond: cond)

        case .cond(let words):
            var args: [(String, Bool)] = []
            for w in words {
                if let lit = w.plainLiteral, ["&&", "||", "(", ")", "<", ">", "!"].contains(lit) {
                    args.append((lit, false))
                } else {
                    args.append((try await expandWordNoSplit(w), w.isFullyQuoted))
                }
            }
            let ok = try ShellTest.evaluate(args, extended: true, interp: self)
            let st: Int32 = ok ? 0 : 1
            state.lastStatus = st
            return try finish(st, cond: cond)

        case .function(let name, let body):
            state.functions[name] = body
            state.lastStatus = 0
            return 0

        case .redirected(let inner, let redirects):
            let newIO = try await applyRedirects(redirects, io)
            return try await execute(inner, newIO, cond: cond)
        }
    }

    private func executeInSubshellIfNeeded(_ node: ShNode, _ io: ShIO, multi: Bool) async throws -> Int32 {
        // In bash ogni elemento di una pipeline gira in una subshell
        guard multi else { return try await execute(node, io, cond: true) }
        let sub = ShellInterpreter(state: state.copy(), host: host)
        sub.state.errexit = false
        do { return try await sub.execute(node, io, cond: true) }
        catch ShellControl.exit(let code) { return code }
    }

    private func finish(_ st: Int32, cond: Bool) throws -> Int32 {
        state.lastStatus = st
        if st != 0 && state.errexit && !cond { throw ShellControl.exit(st) }
        return st
    }

    // MARK: Comandi semplici

    private func executeSimple(_ cmd: ShSimple, _ io: ShIO) async throws -> Int32 {
        state.lastStatus = 0
        var argv: [String] = []
        for w in cmd.words { argv.append(contentsOf: try await expandWord(w)) }
        let cmdSubStatus = state.lastStatus

        var assigned: [(String, String, Bool)] = []
        for a in cmd.assignments {
            var v = try await expandWordNoSplit(a.value)
            if v.hasPrefix("~") { v = expandTilde(v) }
            assigned.append((a.name, v, a.append))
        }

        if argv.isEmpty {
            for (name, value, append) in assigned {
                let nv = append ? (state.vars[name] ?? "") + value : value
                state.setVar(name, nv)
                if host.debugTrace || state.xtrace { io.stderr.write("+ \(name)=\(nv)\n") }
            }
            _ = try await applyRedirects(cmd.redirects, io)
            return cmdSubStatus
        }

        if state.xtrace {
            let pre = assigned.map { "\($0.0)=\($0.1)" }
            io.stderr.write("+ " + (pre + argv.map(shellQuoteIfNeeded)).joined(separator: " ") + "\n")
        }

        let cmdIO = try await applyRedirects(cmd.redirects, io)

        // Assegnazioni temporanee per la durata del comando
        var saved: [(String, String?, Bool)] = []
        for (name, value, append) in assigned {
            saved.append((name, state.vars[name], state.exported.contains(name)))
            let nv = append ? (state.vars[name] ?? "") + value : value
            state.setVar(name, nv, export: true)
        }
        defer {
            for (name, old, wasExported) in saved {
                if let o = old { state.vars[name] = o } else { state.vars.removeValue(forKey: name) }
                if !wasExported { state.exported.remove(name) }
            }
        }
        return try await invoke(argv, cmdIO)
    }

    /// Invoca funzione, builtin o script.
    func invoke(_ argv: [String], _ io: ShIO, skipFunctions: Bool = false) async throws -> Int32 {
        guard let name = argv.first else { return 0 }
        try host.checkInterrupt()
        if !skipFunctions, let body = state.functions[name] {
            return try await callFunction(name, body, Array(argv.dropFirst()), io)
        }
        if let st = try await ShellBuiltins.run(argv, io, self) { return st }
        // Script nel workspace (./build.sh, scripts/x.sh)
        if name.contains("/") {
            return try await runScriptFile(path: name, args: Array(argv.dropFirst()), io: io)
        }
        io.stderr.write(ShellBuiltins.notFoundMessage(name))
        return 127
    }

    private func callFunction(_ name: String, _ body: ShNode, _ args: [String], _ io: ShIO) async throws -> Int32 {
        let savedPositional = state.positional
        state.positional = args
        state.localFrames.append([:])
        defer {
            if let frame = state.localFrames.popLast() {
                for (k, v) in frame {
                    if let old = v { state.vars[k] = old } else { state.vars.removeValue(forKey: k) }
                }
            }
            state.positional = savedPositional
        }
        do {
            return try await execute(body, io, cond: false)
        } catch ShellControl.returned(let code) {
            state.lastStatus = code
            return code
        }
    }

    func runScriptFile(path: String, args: [String], io: ShIO, sourceInCurrent: Bool = false) async throws -> Int32 {
        let url = resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            io.stderr.write("bash: \(path): File o directory non esistente\n")
            return 127
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            io.stderr.write("bash: \(path): impossibile leggere il file\n")
            return 126
        }
        if text.hasPrefix("#!") {
            let shebang = text.prefix { $0 != "\n" }
            let ok = ["bash", "/sh", " sh", "zsh", "dash", "ksh"].contains { shebang.contains($0) }
            if !ok {
                io.stderr.write("\(path): l'interprete '\(shebang.dropFirst(2))' non è disponibile nell'interprete integrato: esegui lo step nella VM Linux (Impostazioni → Esecuzione degli step).\n")
                return 126
            }
        }
        if sourceInCurrent {
            let savedPositional = state.positional
            if !args.isEmpty { state.positional = args }
            defer { state.positional = savedPositional }
            let node = try ShellParser.parse(text)
            do { return try await execute(node, io, cond: false) }
            catch ShellControl.returned(let code) { return code }
        }
        let child = state.childProcess()
        child.scriptName = path
        child.positional = args
        let sub = ShellInterpreter(state: child, host: host)
        return await sub.run(script: text, io: io)
    }

    // MARK: Redirezioni

    func applyRedirects(_ redirects: [ShRedirect], _ io: ShIO) async throws -> ShIO {
        var out = io
        for r in redirects {
            switch r.kind {
            case .output(let append):
                let path = try await expandWordNoSplit(r.target!)
                let sink = sinkFor(path: path, append: append, io: io)
                if r.fd == 2 { out.stderr = sink } else { out.stdout = sink }
            case .both(let append):
                let path = try await expandWordNoSplit(r.target!)
                let sink = sinkFor(path: path, append: append, io: io)
                out.stdout = sink
                out.stderr = sink
            case .input, .readWrite:
                let path = try await expandWordNoSplit(r.target!)
                if path == "/dev/null" { out.stdin = InputSource(""); continue }
                let url = resolve(path)
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    throw ShellRuntimeError(message: "\(path): File o directory non esistente")
                }
                out.stdin = InputSource(text)
            case .dup(let target):
                if r.fd == 2 && target == 1 { out.stderr = out.stdout }
                else if r.fd == 1 && target == 2 { out.stdout = out.stderr }
            case .close:
                if r.fd == 1 { out.stdout = NullSink() } else if r.fd == 2 { out.stderr = NullSink() }
            case .heredoc(let body):
                var text = body.text
                if body.expand {
                    text = try await expandParts(ShellParser.parseHeredocBody(text), inDouble: true).map { $0.text }.joined()
                }
                out.stdin = InputSource(text)
            case .herestring:
                let s = try await expandWordNoSplit(r.target!)
                out.stdin = InputSource(s + "\n")
            }
        }
        return out
    }

    private func sinkFor(path: String, append: Bool, io: ShIO) -> TextSink {
        switch path {
        case "/dev/null": return NullSink()
        case "/dev/stdout", "/dev/fd/1": return io.stdout
        case "/dev/stderr", "/dev/fd/2": return io.stderr
        default: return FileSink(url: resolve(path), append: append)
        }
    }

    // MARK: Percorsi

    /// Risolve un percorso rispetto alla cwd, mappando /tmp e ~ dentro la sandbox dell'app.
    func resolve(_ path: String) -> URL {
        var p = path
        if p.hasPrefix("~") { p = expandTilde(p) }
        if p == "/tmp" || p.hasPrefix("/tmp/") {
            p = (host.tempDir as NSString).appendingPathComponent(String(p.dropFirst(4)))
        } else if p.hasPrefix("/home/runner") && !FileManager.default.fileExists(atPath: "/home/runner") {
            p = (host.homeDir as NSString).appendingPathComponent(String(p.dropFirst("/home/runner".count)))
        }
        if !p.hasPrefix("/") { p = (state.cwd as NSString).appendingPathComponent(p) }
        return URL(fileURLWithPath: p).standardizedFileURL
    }

    func expandTilde(_ s: String) -> String {
        if s == "~" { return state.vars["HOME"] ?? host.homeDir }
        if s.hasPrefix("~/") { return (state.vars["HOME"] ?? host.homeDir) + String(s.dropFirst()) }
        return s
    }

    // MARK: Espansione

    struct Piece {
        var text: String
        var quoted: Bool
        var split: Bool
        var fieldBreak = false
    }

    /// Espansione completa: parametri, sostituzioni, splitting e globbing.
    func expandWord(_ word: ShWord) async throws -> [String] {
        var parts = word.parts
        if case .literal(let l)? = parts.first, l.hasPrefix("~") {
            let end = l.firstIndex(of: "/") ?? l.endIndex
            let tildePart = String(l[..<end])
            if tildePart == "~" {
                parts[0] = .literal(String(l[end...]))
                parts.insert(.quoted(state.vars["HOME"] ?? host.homeDir), at: 0)
            }
        }
        let pieces = try await expandParts(parts, inDouble: false)
        return buildFields(pieces)
    }

    func expandWordNoSplit(_ word: ShWord) async throws -> String {
        var parts = word.parts
        if case .literal(let l)? = parts.first, l == "~" || l.hasPrefix("~/") {
            parts[0] = .literal(expandTilde(l))
        }
        return try await expandParts(parts, inDouble: false).filter { !$0.fieldBreak }.map { $0.text }.joined(separator: "")
    }

    /// Pattern per case/[[ ==]]: le parti quotate vengono protette con escape.
    func expandPattern(_ word: ShWord) async throws -> String {
        let pieces = try await expandParts(word.parts, inDouble: false)
        return pieces.map { $0.quoted ? escapeGlob($0.text) : $0.text }.joined()
    }

    private func escapeGlob(_ s: String) -> String {
        var out = ""
        for c in s {
            if "*?[]\\".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    func expandParts(_ parts: [ShWordPart], inDouble: Bool) async throws -> [Piece] {
        var out: [Piece] = []
        for part in parts {
            switch part {
            case .literal(let s):
                out.append(Piece(text: s, quoted: inDouble, split: false))
            case .quoted(let s):
                out.append(Piece(text: s, quoted: true, split: false))
            case .doubleQuoted(let ps):
                let inner = try await expandParts(ps, inDouble: true)
                if inner.isEmpty { out.append(Piece(text: "", quoted: true, split: false)) }
                out.append(contentsOf: inner)
            case .param(let name):
                if name == "@" && inDouble {
                    for (i, p) in state.positional.enumerated() {
                        if i > 0 { out.append(Piece(text: "", quoted: true, split: false, fieldBreak: true)) }
                        out.append(Piece(text: p, quoted: true, split: false))
                    }
                } else {
                    out.append(Piece(text: try paramValue(name), quoted: inDouble, split: !inDouble))
                }
            case .braced(let inner):
                if inner == "@" && inDouble {
                    out.append(contentsOf: try await expandParts([.param("@")], inDouble: true))
                } else {
                    out.append(Piece(text: try await expandBraced(inner), quoted: inDouble, split: !inDouble))
                }
            case .commandSub(let src):
                let text = try await commandSubstitution(src)
                out.append(Piece(text: text, quoted: inDouble, split: !inDouble))
            case .arith(let src):
                let v = try arith(try await expandArithText(src))
                out.append(Piece(text: String(v), quoted: inDouble, split: !inDouble))
            }
        }
        return out
    }

    private func buildFields(_ pieces: [Piece]) -> [String] {
        var fields: [String] = []
        var current = ""
        var pattern = ""
        var started = false
        var hasGlob = false

        func push() {
            if started {
                if hasGlob && !state.noglob, ShellPattern.hasGlobChars(pattern) {
                    let matches = ShellGlob.expand(pattern, cwd: state.cwd)
                    if matches.isEmpty { fields.append(current) } else { fields.append(contentsOf: matches) }
                } else {
                    fields.append(current)
                }
            }
            current = ""; pattern = ""; started = false; hasGlob = false
        }

        for p in pieces {
            if p.fieldBreak { started = true; push(); started = false; continue }
            if p.split {
                for ch in p.text {
                    if ch == " " || ch == "\t" || ch == "\n" {
                        push()
                    } else {
                        current.append(ch)
                        if "*?[]\\".contains(ch) { pattern.append("\\") }
                        pattern.append(ch)
                        started = true
                    }
                }
            } else {
                current += p.text
                if p.quoted {
                    for ch in p.text {
                        if "*?[]\\".contains(ch) { pattern.append("\\") }
                        pattern.append(ch)
                    }
                } else {
                    pattern += p.text
                    if p.text.contains(where: { "*?[".contains($0) }) { hasGlob = true }
                }
                started = true
            }
        }
        push()
        return fields
    }

    func paramValue(_ name: String) throws -> String {
        switch name {
        case "?": return String(state.lastStatus)
        case "#": return String(state.positional.count)
        case "@", "*": return state.positional.joined(separator: " ")
        case "$": return "4242"
        case "!": return ""
        case "-": return (state.errexit ? "e" : "") + "hB"
        case "0": return state.scriptName
        case "RANDOM": return String(Int.random(in: 0...32767))
        case "SECONDS": return String(Int(Date().timeIntervalSince(state.startDate)))
        case "LINENO": return "0"
        case "BASHPID", "PPID": return "4242"
        case "UID", "EUID": return "1001"
        default: break
        }
        if let n = Int(name) {
            return n >= 1 && n <= state.positional.count ? state.positional[n - 1] : ""
        }
        if let v = state.vars[name] { return v }
        if state.nounset { throw ShellRuntimeError(message: "\(name): variabile non impostata") }
        return ""
    }

    private func isSet(_ name: String) -> Bool {
        if let n = Int(name) { return n == 0 || n <= state.positional.count }
        if ["?", "#", "@", "*", "$", "-", "0", "RANDOM", "SECONDS"].contains(name) { return true }
        return state.vars[name] != nil
    }

    func expandBraced(_ inner: String) async throws -> String {
        let chars = Array(inner)
        guard !chars.isEmpty else { throw ShellRuntimeError(message: "${}: sostituzione errata") }
        // ${#name}
        if chars[0] == "#" && chars.count > 1 {
            let name = String(chars[1...])
            if name == "@" || name == "*" { return String(state.positional.count) }
            return String(try paramValue(name).count)
        }
        // ${!name} (indiretta)
        var indirect = false
        var i = 0
        if chars[0] == "!" && chars.count > 1 { indirect = true; i = 1 }
        var name = ""
        if i < chars.count, chars[i].isLetter || chars[i] == "_" {
            while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { name.append(chars[i]); i += 1 }
        } else if i < chars.count, chars[i].isNumber {
            while i < chars.count, chars[i].isNumber { name.append(chars[i]); i += 1 }
        } else if i < chars.count, "@*#?$!-".contains(chars[i]) {
            name = String(chars[i]); i += 1
        } else {
            throw ShellRuntimeError(message: "${\(inner)}: sostituzione errata")
        }
        if indirect { name = (try? paramValue(name)) ?? "" }
        let rest = String(chars[i...])
        if rest.isEmpty { return try paramValue(name) }
        // ${arr[0]} / ${arr[@]}: supporto minimo (variabile scalare)
        if rest.hasPrefix("[") {
            if rest == "[@]" || rest == "[*]" || rest == "[0]" { return state.vars[name] ?? "" }
            return ""
        }

        let set = isSet(name)
        let value = set ? ((try? paramValue(name)) ?? "") : ""

        func argText(_ op: String) -> String { String(rest.dropFirst(op.count)) }
        func expandArg(_ op: String) async throws -> String {
            try await expandWordNoSplit(ShellParser.parseWordString(argText(op)))
        }

        for op in [":-", ":=", ":+", ":?", "-", "=", "+", "?"] where rest.hasPrefix(op) {
            let colon = op.hasPrefix(":")
            let useAlt = colon ? (set && !value.isEmpty) : set
            switch op.last! {
            case "-":
                if useAlt { return value }
                return try await expandArg(op)
            case "=":
                if useAlt { return value }
                let v = try await expandArg(op)
                state.setVar(name, v)
                return v
            case "+":
                if useAlt { return try await expandArg(op) }
                return ""
            case "?":
                if useAlt { return value }
                let msg = try await expandArg(op)
                throw ShellRuntimeError(message: "\(name): \(msg.isEmpty ? "parametro nullo o non impostato" : msg)")
            default: break
            }
        }
        if rest.hasPrefix("##") { return ShellPattern.removePrefix(value, try await patternArg(argText("##")), longest: true) }
        if rest.hasPrefix("#") { return ShellPattern.removePrefix(value, try await patternArg(argText("#")), longest: false) }
        if rest.hasPrefix("%%") { return ShellPattern.removeSuffix(value, try await patternArg(argText("%%")), longest: true) }
        if rest.hasPrefix("%") { return ShellPattern.removeSuffix(value, try await patternArg(argText("%")), longest: false) }
        if rest.hasPrefix("/") {
            var body = String(rest.dropFirst())
            var all = false
            var anchor: Character? = nil
            if body.hasPrefix("/") { all = true; body.removeFirst() }
            else if body.hasPrefix("#") { anchor = "#"; body.removeFirst() }
            else if body.hasPrefix("%") { anchor = "%"; body.removeFirst() }
            var patText = body
            var repText = ""
            if let slash = ShellBuiltins.unescapedIndex(of: "/", in: body) {
                patText = String(body[..<slash])
                repText = String(body[body.index(after: slash)...])
            }
            let pat = try await patternArg(patText)
            let rep = try await expandWordNoSplit(ShellParser.parseWordString(repText))
            return ShellPattern.replace(value, pat, with: rep, all: all, anchor: anchor)
        }
        if rest == "^^" { return value.uppercased() }
        if rest == ",," { return value.lowercased() }
        if rest == "^" { return value.prefix(1).uppercased() + value.dropFirst() }
        if rest == "," { return value.prefix(1).lowercased() + value.dropFirst() }
        if rest == "@Q" { return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        if rest.hasPrefix(":") {
            let spec = String(rest.dropFirst())
            let comps = spec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let chars = Array(value)
            var offset = Int(try arith(comps[0].trimmingCharacters(in: .whitespaces).isEmpty ? "0" : comps[0]))
            if offset < 0 { offset = max(0, chars.count + offset) }
            offset = min(offset, chars.count)
            var length = chars.count - offset
            if comps.count > 1 {
                let l = Int(try arith(comps[1]))
                length = l < 0 ? max(0, chars.count - offset + l) : min(l, chars.count - offset)
            }
            return String(chars[offset..<(offset + length)])
        }
        throw ShellRuntimeError(message: "${\(inner)}: sostituzione errata")
    }

    private func patternArg(_ text: String) async throws -> String {
        try await expandPattern(ShellParser.parseWordString(text))
    }

    func commandSubstitution(_ src: String) async throws -> String {
        let sub = ShellInterpreter(state: state.copy(), host: host)
        sub.state.errexit = false
        let buffer = BufferSink()
        let node: ShNode
        do { node = try ShellParser.parse(src) } catch {
            throw ShellRuntimeError(message: "sostituzione di comando: \(error.localizedDescription)")
        }
        var st: Int32 = 0
        do { st = try await sub.execute(node, ShIO(stdin: InputSource.empty, stdout: buffer, stderr: currentStderr ?? NullSink()), cond: false) }
        catch ShellControl.exit(let code) { st = code }
        catch ShellControl.returned(let code) { st = code }
        state.lastStatus = st
        var text = buffer.text
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    /// stderr corrente (impostato dal runner per i messaggi delle sostituzioni).
    var currentStderr: TextSink?

    // MARK: Aritmetica

    func expandArithText(_ text: String) async throws -> String {
        guard text.contains("$") || text.contains("`") else { return text }
        let word = ShellParser.parseWordString(text)
        return try await expandWordNoSplit(word)
    }

    func arith(_ text: String) throws -> Int64 {
        var evaluator = ArithEvaluator(text: text, interp: self)
        return try evaluator.evaluate()
    }

    func shellQuoteIfNeeded(_ s: String) -> String {
        if s.isEmpty { return "''" }
        if s.contains(where: { " \t\n'\"$`\\*?[]|&;<>(){}".contains($0) }) {
            return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return s
    }
}

// MARK: - Glob su filesystem

enum ShellGlob {
    static func expand(_ pattern: String, cwd: String) -> [String] {
        let absolute = pattern.hasPrefix("/")
        let comps = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var results: [(display: String, path: String)] = [(absolute ? "/" : "", absolute ? "/" : cwd)]
        let fm = FileManager.default
        for (idx, comp) in comps.enumerated() {
            let isLast = idx == comps.count - 1
            var next: [(String, String)] = []
            for (display, path) in results {
                if !ShellPattern.hasGlobChars(comp) {
                    let lit = ShellPattern.unescape(comp)
                    let np = (path as NSString).appendingPathComponent(lit)
                    if isLast ? fm.fileExists(atPath: np) : isDir(np) {
                        next.append((join(display, lit), np))
                    }
                    continue
                }
                guard let entries = try? fm.contentsOfDirectory(atPath: path) else { continue }
                for e in entries.sorted() {
                    if e.hasPrefix(".") && !comp.hasPrefix(".") { continue }
                    if ShellPattern.matches(e, comp) {
                        let np = (path as NSString).appendingPathComponent(e)
                        if !isLast && !isDir(np) { continue }
                        next.append((join(display, e), np))
                    }
                }
            }
            results = next
            if results.isEmpty { return [] }
        }
        return results.map { $0.display }
    }

    private static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if a.hasSuffix("/") { return a + b }
        return a + "/" + b
    }

    private static func isDir(_ p: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue
    }
}

// MARK: - Valutatore aritmetico $(( ))

struct ArithEvaluator {
    private enum Tok: Equatable { case num(Int64), ident(String), op(String), end }
    private var toks: [Tok] = []
    private var pos = 0
    private let interp: ShellInterpreter

    init(text: String, interp: ShellInterpreter) {
        self.interp = interp
        toks = ArithEvaluator.lex(text)
    }

    private static func lex(_ text: String) -> [Tok] {
        var out: [Tok] = []
        let c = Array(text)
        var i = 0
        let ops3 = ["<<=", ">>=", "**="]
        let ops2 = ["**", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||", "++", "--", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^="]
        while i < c.count {
            let x = c[i]
            if x.isWhitespace { i += 1; continue }
            if x.isNumber {
                var s = ""
                while i < c.count, c[i].isNumber || c[i].isLetter || c[i] == "#" { s.append(c[i]); i += 1 }
                var v: Int64 = 0
                if s.hasPrefix("0x") || s.hasPrefix("0X") { v = Int64(s.dropFirst(2), radix: 16) ?? 0 }
                else if let hash = s.firstIndex(of: "#"), let base = Int(s[..<hash]) { v = Int64(s[s.index(after: hash)...], radix: base) ?? 0 }
                else if s.count > 1, s.hasPrefix("0") { v = Int64(s.dropFirst(), radix: 8) ?? 0 }
                else { v = Int64(s) ?? 0 }
                out.append(.num(v))
                continue
            }
            if x.isLetter || x == "_" {
                var s = ""
                while i < c.count, c[i].isLetter || c[i].isNumber || c[i] == "_" { s.append(c[i]); i += 1 }
                out.append(.ident(s))
                continue
            }
            if i + 2 < c.count, ops3.contains(String(c[i...(i + 2)])) { out.append(.op(String(c[i...(i + 2)]))); i += 3; continue }
            if i + 1 < c.count, ops2.contains(String(c[i...(i + 1)])) { out.append(.op(String(c[i...(i + 1)]))); i += 2; continue }
            out.append(.op(String(x)))
            i += 1
        }
        out.append(.end)
        return out
    }

    mutating func evaluate() throws -> Int64 {
        if toks == [.end] { return 0 }
        var v = try comma()
        if toks[pos] != .end { throw ShellRuntimeError(message: "errore di sintassi nell'espressione aritmetica") }
        v = v + 0
        return v
    }

    private var peek: Tok { toks[pos] }
    private mutating func next() -> Tok { let t = toks[pos]; if pos < toks.count - 1 { pos += 1 }; return t }

    private func value(of name: String) throws -> Int64 {
        let raw = (try? interp.paramValue(name)) ?? ""
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return 0 }
        if let v = Int64(s) { return v }
        if s.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil, s != name { return try value(of: s) }
        var nested = ArithEvaluator(text: s, interp: interp)
        return try nested.evaluate()
    }

    private func assign(_ name: String, _ v: Int64) { interp.state.setVar(name, String(v)) }

    private mutating func comma() throws -> Int64 {
        var v = try assignment()
        while peek == .op(",") { _ = next(); v = try assignment() }
        return v
    }

    private mutating func assignment() throws -> Int64 {
        if case .ident(let name) = peek, pos + 1 < toks.count, case .op(let op) = toks[pos + 1],
           ["=", "+=", "-=", "*=", "/=", "%=", "<<=", ">>=", "&=", "|=", "^=", "**="].contains(op) {
            pos += 2
            let rhs = try assignment()
            let cur = try value(of: name)
            var v: Int64
            switch op {
            case "=": v = rhs
            case "+=": v = cur &+ rhs
            case "-=": v = cur &- rhs
            case "*=": v = cur &* rhs
            case "/=": guard rhs != 0 else { throw ShellRuntimeError(message: "divisione per 0") }; v = cur / rhs
            case "%=": guard rhs != 0 else { throw ShellRuntimeError(message: "divisione per 0") }; v = cur % rhs
            case "<<=": v = cur << rhs
            case ">>=": v = cur >> rhs
            case "&=": v = cur & rhs
            case "|=": v = cur | rhs
            case "^=": v = cur ^ rhs
            default: v = ArithEvaluator.power(cur, rhs)
            }
            assign(name, v)
            return v
        }
        return try ternary()
    }

    private mutating func ternary() throws -> Int64 {
        let c = try binary(0)
        if peek == .op("?") {
            _ = next()
            let a = try assignment()
            guard next() == .op(":") else { throw ShellRuntimeError(message: "atteso ':' nell'operatore ternario") }
            let b = try assignment()
            return c != 0 ? a : b
        }
        return c
    }

    private static let levels: [[String]] = [
        ["||"], ["&&"], ["|"], ["^"], ["&"], ["==", "!="], ["<", "<=", ">", ">="], ["<<", ">>"], ["+", "-"], ["*", "/", "%"]
    ]

    private mutating func binary(_ level: Int) throws -> Int64 {
        if level >= ArithEvaluator.levels.count { return try power() }
        var left = try binary(level + 1)
        while case .op(let op) = peek, ArithEvaluator.levels[level].contains(op) {
            _ = next()
            let right = try binary(level + 1)
            switch op {
            case "||": left = (left != 0 || right != 0) ? 1 : 0
            case "&&": left = (left != 0 && right != 0) ? 1 : 0
            case "|": left = left | right
            case "^": left = left ^ right
            case "&": left = left & right
            case "==": left = left == right ? 1 : 0
            case "!=": left = left != right ? 1 : 0
            case "<": left = left < right ? 1 : 0
            case "<=": left = left <= right ? 1 : 0
            case ">": left = left > right ? 1 : 0
            case ">=": left = left >= right ? 1 : 0
            case "<<": left = left << right
            case ">>": left = left >> right
            case "+": left = left &+ right
            case "-": left = left &- right
            case "*": left = left &* right
            case "/": guard right != 0 else { throw ShellRuntimeError(message: "divisione per 0") }; left = left / right
            case "%": guard right != 0 else { throw ShellRuntimeError(message: "divisione per 0") }; left = left % right
            default: break
            }
        }
        return left
    }

    static func power(_ a: Int64, _ b: Int64) -> Int64 {
        guard b >= 0 else { return 0 }
        var r: Int64 = 1
        var i: Int64 = 0
        while i < b { r = r &* a; i += 1 }
        return r
    }

    private mutating func power() throws -> Int64 {
        let base = try unary()
        if peek == .op("**") { _ = next(); return ArithEvaluator.power(base, try power()) }
        return base
    }

    private mutating func unary() throws -> Int64 {
        switch peek {
        case .op("-"):
            _ = next()
            let v = try unary()
            return 0 &- v
        case .op("+"): _ = next(); return try unary()
        case .op("!"):
            _ = next()
            let v = try unary()
            return v == 0 ? 1 : 0
        case .op("~"):
            _ = next()
            let v = try unary()
            return ~v
        case .op("++"), .op("--"):
            let op = next()
            guard case .ident(let name) = next() else { throw ShellRuntimeError(message: "++/-- richiede una variabile") }
            let v = try value(of: name) + (op == .op("++") ? 1 : -1)
            assign(name, v)
            return v
        default: return try postfix()
        }
    }

    private mutating func postfix() throws -> Int64 {
        let t = next()
        switch t {
        case .num(let n): return n
        case .ident(let name):
            let v = try value(of: name)
            if peek == .op("++") { _ = next(); assign(name, v + 1); return v }
            if peek == .op("--") { _ = next(); assign(name, v - 1); return v }
            return v
        case .op("("):
            let v = try comma()
            guard next() == .op(")") else { throw ShellRuntimeError(message: "')' mancante nell'espressione aritmetica") }
            return v
        default:
            throw ShellRuntimeError(message: "errore di sintassi nell'espressione aritmetica")
        }
    }
}
