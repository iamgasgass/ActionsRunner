import Foundation

// MARK: - AST

enum ShWordPart {
    case literal(String)            // testo non quotato (soggetto a glob)
    case quoted(String)             // testo quotato o con escape (letterale)
    case doubleQuoted([ShWordPart])
    case param(String)              // $name, $1, $?
    case braced(String)             // ${...} (testo interno)
    case commandSub(String)         // $(...) o `...`
    case arith(String)              // $((...))
}

struct ShWord {
    var parts: [ShWordPart]

    /// Testo letterale se la parola non contiene espansioni né quoting.
    var plainLiteral: String? {
        var s = ""
        for p in parts {
            guard case .literal(let l) = p else { return nil }
            s += l
        }
        return s
    }

    /// true se la parola è interamente quotata (usato da [[ == ]]).
    var isFullyQuoted: Bool {
        !parts.isEmpty && parts.allSatisfy {
            switch $0 {
            case .quoted, .doubleQuoted: return true
            default: return false
            }
        }
    }

    static func literal(_ s: String) -> ShWord { ShWord(parts: [.literal(s)]) }
}

final class HeredocBody {
    var text = ""
    let expand: Bool
    let stripTabs: Bool
    let delimiter: String
    init(delimiter: String, expand: Bool, stripTabs: Bool) {
        self.delimiter = delimiter
        self.expand = expand
        self.stripTabs = stripTabs
    }
}

struct ShRedirect {
    enum Kind {
        case output(append: Bool)   // > >>
        case input                  // <
        case both(append: Bool)     // &> &>>
        case dup(Int)               // n>&m
        case close                  // n>&-
        case heredoc(HeredocBody)   // << <<-
        case herestring             // <<<
        case readWrite              // <>
    }
    var fd: Int
    var kind: Kind
    var target: ShWord?
}

struct ShAssignment {
    var name: String
    var value: ShWord
    var append: Bool
}

struct ShSimple {
    var assignments: [ShAssignment] = []
    var words: [ShWord] = []
    var redirects: [ShRedirect] = []
}

struct ShCaseItem {
    var patterns: [ShWord]
    var body: ShNode
    var fallthroughMode: String // ";;", ";&", ";;&"
}

struct ShIfBranch {
    var condition: ShNode
    var body: ShNode
}

struct ShAndOrPart {
    var op: String  // "&&" o "||"
    var node: ShNode
}

indirect enum ShNode {
    case empty
    case simple(ShSimple)
    case pipeline([ShNode], negated: Bool)
    case andOr(ShNode, [ShAndOrPart])
    case sequence([ShNode])
    case ifClause([ShIfBranch], ShNode?)
    case forClause(String, [ShWord]?, ShNode)
    case cFor(String, String, String, ShNode)
    case whileClause(ShNode, ShNode, until: Bool)
    case caseClause(ShWord, [ShCaseItem])
    case group(ShNode, subshell: Bool)
    case arith(String)
    case cond([ShWord])
    case function(String, ShNode)
    case redirected(ShNode, [ShRedirect])
}

struct ShellSyntaxError: LocalizedError {
    let message: String
    let line: Int
    var errorDescription: String? { "errore di sintassi (riga \(line)): \(message)" }
}

// MARK: - Parser

struct ShellParser {
    private let c: [Character]
    private var pos = 0
    private var pendingHeredocs: [HeredocBody] = []

    static let reserved: Set<String> = ["if", "then", "elif", "else", "fi", "do", "done", "case", "esac",
                                        "while", "until", "for", "in", "function", "{", "}", "!", "[[", "]]", "select", "time"]

    init(_ source: String) {
        c = Array(source)
    }

    static func parse(_ source: String) throws -> ShNode {
        var p = ShellParser(source)
        let node = try p.parseList(terminators: [])
        p.skipLinebreaks()
        if p.pos < p.c.count {
            throw ShellSyntaxError(message: "token inatteso '\(p.peekToken())'", line: p.lineNumber)
        }
        return node
    }

    /// Analizza una stringa come singola parola (spazi letterali), usata per gli argomenti di ${x:-...}.
    static func parseWordString(_ s: String) -> ShWord {
        var p = ShellParser(s)
        var parts: [ShWordPart] = []
        var lit = ""
        func flush() { if !lit.isEmpty { parts.append(.literal(lit)); lit = "" } }
        while p.pos < p.c.count {
            let ch = p.c[p.pos]
            switch ch {
            case "\\":
                flush()
                if p.pos + 1 < p.c.count { parts.append(.quoted(String(p.c[p.pos + 1]))); p.pos += 2 } else { p.pos += 1 }
            case "'":
                flush()
                if let q = try? p.readSingleQuoted() { parts.append(.quoted(q)) }
            case "\"":
                flush()
                if let dq = try? p.readDoubleQuoted() { parts.append(.doubleQuoted(dq)) }
            case "$":
                flush()
                if let d = try? p.readDollar() { parts.append(d) }
            case "`":
                flush()
                if let b = try? p.readBacktick() { parts.append(.commandSub(b)) }
            default:
                lit.append(ch); p.pos += 1
            }
        }
        flush()
        return ShWord(parts: parts)
    }

    /// Parsing del corpo di un heredoc non quotato (come stringa tra doppi apici, ma " è letterale).
    static func parseHeredocBody(_ s: String) -> [ShWordPart] {
        var p = ShellParser(s)
        var parts: [ShWordPart] = []
        var lit = ""
        func flush() { if !lit.isEmpty { parts.append(.quoted(lit)); lit = "" } }
        while p.pos < p.c.count {
            let ch = p.c[p.pos]
            if ch == "\\", p.pos + 1 < p.c.count, "$`\\\n".contains(p.c[p.pos + 1]) {
                if p.c[p.pos + 1] != "\n" { lit.append(p.c[p.pos + 1]) }
                p.pos += 2
            } else if ch == "$" {
                flush()
                if let d = try? p.readDollar() { parts.append(d) } else { lit.append("$"); p.pos += 1 }
            } else if ch == "`" {
                flush()
                if let b = try? p.readBacktick() { parts.append(.commandSub(b)) }
            } else {
                lit.append(ch); p.pos += 1
            }
        }
        flush()
        return parts
    }

    private var lineNumber: Int {
        var n = 1
        var i = 0
        while i < pos && i < c.count { if c[i] == "\n" { n += 1 }; i += 1 }
        return n
    }

    private func err(_ m: String) -> ShellSyntaxError { ShellSyntaxError(message: m, line: lineNumber) }

    // MARK: Lessico di base

    private var atEnd: Bool { pos >= c.count }
    private func ch(_ offset: Int = 0) -> Character? { pos + offset < c.count ? c[pos + offset] : nil }

    private static func isMeta(_ ch: Character) -> Bool { " \t\n;&|<>()".contains(ch) }

    private mutating func skipBlanks() {
        while let x = ch() {
            if x == " " || x == "\t" || x == "\r" { pos += 1 }
            else if x == "\\", ch(1) == "\n" { pos += 2 }
            else { break }
        }
    }

    private mutating func skipComment() {
        if ch() == "#" { while let x = ch(), x != "\n" { pos += 1 } }
    }

    private mutating func consumeNewline() {
        pos += 1
        readPendingHeredocs()
    }

    private mutating func skipLinebreaks() {
        while true {
            skipBlanks()
            skipComment()
            if ch() == "\n" { consumeNewline() } else { break }
        }
    }

    private mutating func readPendingHeredocs() {
        guard !pendingHeredocs.isEmpty else { return }
        let docs = pendingHeredocs
        pendingHeredocs.removeAll()
        for doc in docs {
            var body = ""
            while pos < c.count {
                var end = pos
                while end < c.count, c[end] != "\n" { end += 1 }
                var line = String(c[pos..<end])
                pos = min(end + 1, c.count)
                if doc.stripTabs { while line.hasPrefix("\t") { line.removeFirst() } }
                if line == doc.delimiter || line.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) == doc.delimiter { break }
                body += line + "\n"
            }
            doc.text = body
        }
    }

    private func peekToken() -> String {
        var i = pos
        var s = ""
        while i < c.count, !ShellParser.isMeta(c[i]) { s.append(c[i]); i += 1 }
        if s.isEmpty, i < c.count { s = String(c[i]) }
        return s
    }

    /// Restituisce la parola riservata alla posizione corrente (senza consumarla).
    private func peekReserved() -> String? {
        var i = pos
        var s = ""
        while i < c.count, !ShellParser.isMeta(c[i]) {
            let x = c[i]
            if x == "'" || x == "\"" || x == "$" || x == "\\" || x == "`" { return nil }
            s.append(x); i += 1
        }
        return ShellParser.reserved.contains(s) ? s : nil
    }

    private mutating func consumeReserved(_ w: String) {
        pos += w.count
    }

    private mutating func expectReserved(_ w: String) throws {
        skipLinebreaks()
        guard peekReserved() == w else { throw err("atteso '\(w)', trovato '\(peekToken())'") }
        consumeReserved(w)
    }

    private func peekOp(_ op: String) -> Bool {
        let chars = Array(op)
        guard pos + chars.count <= c.count else { return false }
        for (i, x) in chars.enumerated() where c[pos + i] != x { return false }
        return true
    }

    // MARK: Liste

    private mutating func parseList(terminators: Set<String>, opTerminators: Set<String> = []) throws -> ShNode {
        var items: [ShNode] = []
        while true {
            skipLinebreaks()
            if atEnd { break }
            if let r = peekReserved(), terminators.contains(r) { break }
            if opTerminators.contains(where: { peekOp($0) }) { break }
            if ch() == ")" { break }
            let node = try parseAndOr()
            items.append(node)
            skipBlanks()
            skipComment()
            if peekOp(";;") || peekOp(";&") { break }
            if ch() == ";" { pos += 1; continue }
            if ch() == "&", !peekOp("&&") { pos += 1; continue }
            if ch() == "\n" { consumeNewline(); continue }
            if atEnd { break }
            if let r = peekReserved(), terminators.contains(r) { break }
            if ch() == ")" { break }
            throw err("token inatteso '\(peekToken())'")
        }
        if items.isEmpty { return .empty }
        return items.count == 1 ? items[0] : .sequence(items)
    }

    private mutating func parseAndOr() throws -> ShNode {
        let first = try parsePipeline()
        var rest: [ShAndOrPart] = []
        while true {
            skipBlanks()
            if peekOp("&&") {
                pos += 2; skipLinebreaks()
                rest.append(ShAndOrPart(op: "&&", node: try parsePipeline()))
            } else if peekOp("||") {
                pos += 2; skipLinebreaks()
                rest.append(ShAndOrPart(op: "||", node: try parsePipeline()))
            } else { break }
        }
        return rest.isEmpty ? first : .andOr(first, rest)
    }

    private mutating func parsePipeline() throws -> ShNode {
        skipBlanks()
        var negated = false
        if peekReserved() == "time" { consumeReserved("time"); skipBlanks() }
        if peekReserved() == "!" { consumeReserved("!"); negated = true; skipBlanks() }
        var cmds = [try parseCommand()]
        while true {
            skipBlanks()
            if ch() == "|", !peekOp("||") {
                pos += 1
                if ch() == "&" { pos += 1 }
                skipLinebreaks()
                cmds.append(try parseCommand())
            } else { break }
        }
        if cmds.count == 1 && !negated { return cmds[0] }
        return .pipeline(cmds, negated: negated)
    }

    // MARK: Comandi

    private mutating func parseCommand() throws -> ShNode {
        skipBlanks()
        var node: ShNode
        if let r = peekReserved() {
            switch r {
            case "if": node = try parseIf()
            case "for": node = try parseFor()
            case "while", "until": node = try parseWhile()
            case "case": node = try parseCase()
            case "{":
                consumeReserved("{")
                let body = try parseList(terminators: ["}"])
                try expectReserved("}")
                node = .group(body, subshell: false)
            case "[[":
                consumeReserved("[[")
                node = .cond(try parseCondWords())
            case "function":
                consumeReserved("function")
                skipBlanks()
                let nameWord = try readWord()
                guard let name = nameWord.plainLiteral else { throw err("nome di funzione non valido") }
                skipBlanks()
                if peekOp("()") { pos += 2 }
                skipLinebreaks()
                node = .function(name, try parseCommand())
                return node
            default:
                throw err("parola riservata inattesa '\(r)'")
            }
        } else if peekOp("((") {
            pos += 2
            let start = pos
            var depth = 0
            while pos < c.count {
                if c[pos] == "(" { depth += 1 }
                else if c[pos] == ")" {
                    if depth == 0, ch(1) == ")" { break }
                    depth -= 1
                }
                pos += 1
            }
            guard pos < c.count else { throw err("'((' non chiusa") }
            let inner = String(c[start..<pos])
            pos += 2
            node = .arith(inner)
        } else if ch() == "(" {
            pos += 1
            let body = try parseList(terminators: [])
            skipLinebreaks()
            guard ch() == ")" else { throw err("atteso ')'") }
            pos += 1
            node = .group(body, subshell: true)
        } else {
            return try parseSimple()
        }
        // redirezioni dopo un comando composto
        var redirects: [ShRedirect] = []
        while true {
            skipBlanks()
            if let r = try parseRedirectIfPresent() { redirects.append(r) } else { break }
        }
        return redirects.isEmpty ? node : .redirected(node, redirects)
    }

    private mutating func parseCondWords() throws -> [ShWord] {
        var words: [ShWord] = []
        while true {
            skipBlanks()
            if ch() == "\n" { consumeNewline(); continue }
            guard !atEnd else { throw err("']]' mancante") }
            if peekReserved() == "]]" { consumeReserved("]]"); return words }
            var matchedOp = false
            for op in ["&&", "||", "(", ")", "<", ">"] where peekOp(op) {
                pos += op.count
                words.append(.literal(op))
                matchedOp = true
                break
            }
            if matchedOp { continue }
            if let x = ch(), ShellParser.isMeta(x) {
                throw err("token inatteso '\(x)' dentro [[ ]]")
            }
            words.append(try readWord(condMode: true))
        }
    }

    private mutating func parseIf() throws -> ShNode {
        consumeReserved("if")
        var branches: [ShIfBranch] = []
        let cond = try parseList(terminators: ["then"])
        try expectReserved("then")
        let body = try parseList(terminators: ["elif", "else", "fi"])
        branches.append(ShIfBranch(condition: cond, body: body))
        var elseBody: ShNode? = nil
        while true {
            skipLinebreaks()
            if peekReserved() == "elif" {
                consumeReserved("elif")
                let c2 = try parseList(terminators: ["then"])
                try expectReserved("then")
                let b2 = try parseList(terminators: ["elif", "else", "fi"])
                branches.append(ShIfBranch(condition: c2, body: b2))
            } else if peekReserved() == "else" {
                consumeReserved("else")
                elseBody = try parseList(terminators: ["fi"])
            } else { break }
        }
        try expectReserved("fi")
        return .ifClause(branches, elseBody)
    }

    private mutating func parseFor() throws -> ShNode {
        consumeReserved("for")
        skipBlanks()
        if peekOp("((") {
            pos += 2
            let start = pos
            var depth = 0
            while pos < c.count {
                if c[pos] == "(" { depth += 1 }
                else if c[pos] == ")" { if depth == 0, ch(1) == ")" { break }; depth -= 1 }
                pos += 1
            }
            let inner = String(c[start..<min(pos, c.count)])
            pos += 2
            let parts = inner.components(separatedBy: ";")
            guard parts.count == 3 else { throw err("for (( ; ; )) non valido") }
            skipBlanks()
            if ch() == ";" { pos += 1 }
            try expectReserved("do")
            let body = try parseList(terminators: ["done"])
            try expectReserved("done")
            return .cFor(parts[0], parts[1], parts[2], body)
        }
        let nameWord = try readWord()
        guard let name = nameWord.plainLiteral else { throw err("nome variabile del for non valido") }
        skipBlanks()
        var items: [ShWord]? = nil
        // "in" può stare sulla stessa riga o dopo newline
        let save = pos
        skipLinebreaks()
        if peekReserved() == "in" {
            consumeReserved("in")
            var list: [ShWord] = []
            while true {
                skipBlanks()
                if ch() == ";" || ch() == "\n" || atEnd { break }
                list.append(try readWord())
            }
            items = list
        } else {
            pos = save
        }
        skipBlanks()
        if ch() == ";" { pos += 1 }
        try expectReserved("do")
        let body = try parseList(terminators: ["done"])
        try expectReserved("done")
        return .forClause(name, items, body)
    }

    private mutating func parseWhile() throws -> ShNode {
        let isUntil = peekReserved() == "until"
        consumeReserved(isUntil ? "until" : "while")
        let cond = try parseList(terminators: ["do"])
        try expectReserved("do")
        let body = try parseList(terminators: ["done"])
        try expectReserved("done")
        return .whileClause(cond, body, until: isUntil)
    }

    private mutating func parseCase() throws -> ShNode {
        consumeReserved("case")
        skipBlanks()
        let word = try readWord()
        try expectReserved("in")
        var items: [ShCaseItem] = []
        while true {
            skipLinebreaks()
            if peekReserved() == "esac" { consumeReserved("esac"); break }
            guard !atEnd else { throw err("'esac' mancante") }
            if ch() == "(" { pos += 1 }
            var patterns: [ShWord] = []
            while true {
                skipBlanks()
                patterns.append(try readWord())
                skipBlanks()
                if ch() == "|" { pos += 1; continue }
                if ch() == ")" { pos += 1; break }
                throw err("atteso ')' nel pattern del case")
            }
            let body = try parseList(terminators: ["esac"], opTerminators: [";;", ";&"])
            skipLinebreaks()
            var mode = ";;"
            if peekOp(";;&") { pos += 3; mode = ";;&" }
            else if peekOp(";;") { pos += 2 }
            else if peekOp(";&") { pos += 2; mode = ";&" }
            items.append(ShCaseItem(patterns: patterns, body: body, fallthroughMode: mode))
        }
        return .caseClause(word, items)
    }

    private static let assignmentRegex = try! NSRegularExpression(pattern: "^([A-Za-z_][A-Za-z0-9_]*)(\\+?)=")

    private mutating func parseSimple() throws -> ShNode {
        var cmd = ShSimple()
        while true {
            skipBlanks()
            guard let x = ch() else { break }
            if x == "#" && cmd.words.isEmpty && cmd.assignments.isEmpty { skipComment(); break }
            if x == "\n" || x == ";" || x == "|" || x == ")" || (x == "&" && !peekOp("&>")) { break }
            if let r = try parseRedirectIfPresent() { cmd.redirects.append(r); continue }
            if x == "(" {
                // definizione di funzione: name() { ... }
                if peekOp("()"), cmd.words.count == 1, cmd.assignments.isEmpty, let name = cmd.words[0].plainLiteral {
                    pos += 2
                    skipLinebreaks()
                    return .function(name, try parseCommand())
                }
                throw err("'(' inattesa")
            }
            let wordStart = pos
            let word = try readWord()
            // n>file / n<file
            if let lit = word.plainLiteral, !lit.isEmpty, lit.allSatisfy({ $0.isNumber }), let nx = ch(), nx == ">" || nx == "<" {
                if var r = try parseRedirectIfPresent() {
                    r.fd = Int(lit) ?? r.fd
                    cmd.redirects.append(r)
                    continue
                }
            }
            if cmd.words.isEmpty, let first = word.parts.first, case .literal(let lit) = first {
                let range = NSRange(lit.startIndex..., in: lit)
                if let m = ShellParser.assignmentRegex.firstMatch(in: lit, range: range),
                   let nameRange = Range(m.range(at: 1), in: lit), let full = Range(m.range, in: lit) {
                    let name = String(lit[nameRange])
                    let append = m.range(at: 2).length > 0
                    var valueParts = word.parts
                    let rest = String(lit[full.upperBound...])
                    if rest.isEmpty { valueParts.removeFirst() } else { valueParts[0] = .literal(rest) }
                    if valueParts.isEmpty, ch() == "(" {
                        throw err("gli array bash (\(name)=(...)) non sono supportati dall'interprete iOS")
                    }
                    cmd.assignments.append(ShAssignment(name: name, value: ShWord(parts: valueParts), append: append))
                    _ = wordStart
                    continue
                }
            }
            cmd.words.append(word)
        }
        return .simple(cmd)
    }

    private mutating func parseRedirectIfPresent() throws -> ShRedirect? {
        func target() throws -> ShWord {
            skipBlanks()
            guard let x = ch(), !ShellParser.isMeta(x) else { throw err("manca il target della redirezione") }
            return try readWord()
        }
        if peekOp("&>>") { pos += 3; return ShRedirect(fd: 1, kind: .both(append: true), target: try target()) }
        if peekOp("&>") { pos += 2; return ShRedirect(fd: 1, kind: .both(append: false), target: try target()) }
        if peekOp("<<<") { pos += 3; return ShRedirect(fd: 0, kind: .herestring, target: try target()) }
        if peekOp("<<-") || peekOp("<<") {
            let strip = peekOp("<<-")
            pos += strip ? 3 : 2
            skipBlanks()
            let dw = try readWord()
            var delim = ""
            var quoted = false
            for p in dw.parts {
                switch p {
                case .literal(let s): delim += s
                case .quoted(let s): delim += s; quoted = true
                case .doubleQuoted(let ps):
                    quoted = true
                    for q in ps { if case .quoted(let s) = q { delim += s } else if case .literal(let s) = q { delim += s } }
                default: break
                }
            }
            let body = HeredocBody(delimiter: delim, expand: !quoted, stripTabs: strip)
            pendingHeredocs.append(body)
            return ShRedirect(fd: 0, kind: .heredoc(body), target: nil)
        }
        if peekOp("<>") { pos += 2; return ShRedirect(fd: 0, kind: .readWrite, target: try target()) }
        if peekOp(">&") || peekOp("<&") {
            let isOut = ch() == ">"
            pos += 2
            skipBlanks()
            if ch() == "-" { pos += 1; return ShRedirect(fd: isOut ? 1 : 0, kind: .close, target: nil) }
            let w = try readWord()
            if let lit = w.plainLiteral, let n = Int(lit) {
                return ShRedirect(fd: isOut ? 1 : 0, kind: .dup(n), target: nil)
            }
            // >&file equivale a &>file
            return ShRedirect(fd: 1, kind: .both(append: false), target: w)
        }
        if peekOp(">>") { pos += 2; return ShRedirect(fd: 1, kind: .output(append: true), target: try target()) }
        if peekOp(">|") { pos += 2; return ShRedirect(fd: 1, kind: .output(append: false), target: try target()) }
        if ch() == ">" { pos += 1; return ShRedirect(fd: 1, kind: .output(append: false), target: try target()) }
        if ch() == "<" { pos += 1; return ShRedirect(fd: 0, kind: .input, target: try target()) }
        return nil
    }

    // MARK: Parole

    mutating func readWord(condMode: Bool = false) throws -> ShWord {
        var parts: [ShWordPart] = []
        var lit = ""
        func flush() { if !lit.isEmpty { parts.append(.literal(lit)); lit = "" } }
        while let x = ch() {
            if ShellParser.isMeta(x) {
                // in [[ ]] le parentesi dentro una regex fanno parte della parola
                if condMode, x == "(" || x == ")" || (x == "|" && !peekOp("||")), !lit.isEmpty || !parts.isEmpty {
                    lit.append(x); pos += 1; continue
                }
                break
            }
            switch x {
            case "\\":
                flush()
                if ch(1) == "\n" { pos += 2 }
                else if let n = ch(1) { parts.append(.quoted(String(n))); pos += 2 }
                else { pos += 1 }
            case "'":
                flush()
                parts.append(.quoted(try readSingleQuoted()))
            case "\"":
                flush()
                parts.append(.doubleQuoted(try readDoubleQuoted()))
            case "$":
                flush()
                if ch(1) == "'" {
                    pos += 1
                    parts.append(.quoted(ShellParser.ansiC(try readSingleQuoted())))
                } else {
                    parts.append(try readDollar())
                }
            case "`":
                flush()
                parts.append(.commandSub(try readBacktick()))
            default:
                lit.append(x); pos += 1
            }
        }
        flush()
        if parts.isEmpty { throw err("parola attesa, trovato '\(peekToken())'") }
        return ShWord(parts: parts)
    }

    mutating func readSingleQuoted() throws -> String {
        pos += 1
        var s = ""
        while let x = ch() {
            if x == "'" { pos += 1; return s }
            s.append(x); pos += 1
        }
        throw err("apice singolo non chiuso")
    }

    mutating func readDoubleQuoted() throws -> [ShWordPart] {
        pos += 1
        var parts: [ShWordPart] = []
        var lit = ""
        func flush() { if !lit.isEmpty { parts.append(.quoted(lit)); lit = "" } }
        while let x = ch() {
            switch x {
            case "\"":
                pos += 1
                flush()
                return parts
            case "\\":
                if let n = ch(1), "$`\"\\\n".contains(n) {
                    if n != "\n" { lit.append(n) }
                    pos += 2
                } else { lit.append("\\"); pos += 1 }
            case "$":
                if let n = ch(1), n.isLetter || n == "_" || n.isNumber || "{(@*#?$!-".contains(n) {
                    flush()
                    parts.append(try readDollar())
                } else { lit.append("$"); pos += 1 }
            case "`":
                flush()
                parts.append(.commandSub(try readBacktick()))
            default:
                lit.append(x); pos += 1
            }
        }
        throw err("doppio apice non chiuso")
    }

    mutating func readBacktick() throws -> String {
        pos += 1
        var s = ""
        while let x = ch() {
            if x == "\\", let n = ch(1), "`$\\".contains(n) { s.append(n); pos += 2; continue }
            if x == "`" { pos += 1; return s }
            s.append(x); pos += 1
        }
        throw err("backtick non chiuso")
    }

    mutating func readDollar() throws -> ShWordPart {
        // pos su '$'
        if peekOp("$((") {
            pos += 3
            let start = pos
            var depth = 0
            while pos < c.count {
                if c[pos] == "(" { depth += 1 }
                else if c[pos] == ")" {
                    if depth == 0 && ch(1) == ")" { break }
                    depth -= 1
                }
                pos += 1
            }
            guard pos < c.count else { throw err("'$((' non chiusa") }
            let inner = String(c[start..<pos])
            pos += 2
            return .arith(inner)
        }
        if peekOp("$(") {
            pos += 2
            let inner = try scanBalanced(open: "(", close: ")")
            return .commandSub(inner)
        }
        if peekOp("${") {
            pos += 2
            let inner = try scanBalanced(open: "{", close: "}")
            return .braced(inner)
        }
        pos += 1
        guard let x = ch() else { return .quoted("$") }
        if x.isLetter || x == "_" {
            var name = ""
            while let y = ch(), y.isLetter || y.isNumber || y == "_" { name.append(y); pos += 1 }
            return .param(name)
        }
        if x.isNumber || "@*#?$!-".contains(x) {
            pos += 1
            return .param(String(x))
        }
        return .quoted("$")
    }

    /// Scansiona fino alla chiusura bilanciata rispettando apici e annidamenti.
    private mutating func scanBalanced(open: Character, close: Character) throws -> String {
        let start = pos
        var depth = 0
        while let x = ch() {
            switch x {
            case "\\": pos += 2; continue
            case "'":
                if open == "(" || true {
                    pos += 1
                    while let y = ch(), y != "'" { pos += 1 }
                    pos += 1
                    continue
                }
            case "\"":
                pos += 1
                while let y = ch(), y != "\"" {
                    if y == "\\" { pos += 1 }
                    pos += 1
                }
                pos += 1
                continue
            case "`":
                pos += 1
                while let y = ch(), y != "`" { if y == "\\" { pos += 1 }; pos += 1 }
                pos += 1
                continue
            default: break
            }
            if x == open { depth += 1 }
            else if x == close {
                if depth == 0 {
                    let inner = String(c[start..<pos])
                    pos += 1
                    return inner
                }
                depth -= 1
            }
            pos += 1
        }
        throw err("'\(open)' non chiusa")
    }

    static func ansiC(_ s: String) -> String {
        var out = ""
        var it = Array(s)
        var i = 0
        while i < it.count {
            if it[i] == "\\", i + 1 < it.count {
                let n = it[i + 1]
                switch n {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "a": out.append("\u{07}")
                case "b": out.append("\u{08}")
                case "e", "E": out.append("\u{1B}")
                case "\\": out.append("\\")
                case "'": out.append("'")
                case "\"": out.append("\"")
                case "0":
                    var j = i + 2
                    var oct = ""
                    while j < it.count, oct.count < 3, ("0"..."7").contains(it[j]) { oct.append(it[j]); j += 1 }
                    if let v = UInt32(oct.isEmpty ? "0" : oct, radix: 8), let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
                    i = j
                    continue
                case "x":
                    var j = i + 2
                    var hex = ""
                    while j < it.count, hex.count < 2, it[j].isHexDigit { hex.append(it[j]); j += 1 }
                    if let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
                    i = j
                    continue
                default: out.append("\\"); out.append(n)
                }
                i += 2
            } else {
                out.append(it[i]); i += 1
            }
        }
        it.removeAll()
        return out
    }
}
