import Foundation

/// Parser YAML scritto da zero (nessuna dipendenza esterna).
/// Copre il sottoinsieme usato da GitHub Actions e da action.yml:
/// mappe e sequenze a blocchi, collezioni flow, scalari plain/'single'/"double" multilinea,
/// scalari a blocco | e > con indicatori di chomping/indentazione, commenti, ancore, alias,
/// merge key `<<`, tag `!!str` ecc. Gli scalari plain seguono lo schema "core" di YAML 1.2
/// (come GitHub: `on`, `yes`, `no` restano stringhe).
struct YAMLError: LocalizedError {
    let message: String
    let line: Int
    var errorDescription: String? { "YAML non valido (riga \(line)): \(message)" }
}

struct YAMLParser {
    private var lines: [[Character]]
    private var li = 0
    private var anchors: [String: JSONValue] = [:]

    init(_ text: String) {
        var t = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        lines = t.components(separatedBy: "\n").map { Array($0) }
    }

    static func parse(_ text: String) throws -> JSONValue {
        var p = YAMLParser(text)
        return try p.parseDocument()
    }

    // MARK: - Utilità di riga

    private func indentOf(_ l: [Character]) -> Int {
        var i = 0
        while i < l.count, l[i] == " " { i += 1 }
        return i
    }

    private func isBlankOrComment(_ l: [Character]) -> Bool {
        let i = indentOf(l)
        return i >= l.count || l[i] == "#"
    }

    private func err(_ m: String) -> YAMLError { YAMLError(message: m, line: min(li + 1, lines.count)) }

    private mutating func skipBlank() {
        while li < lines.count, isBlankOrComment(lines[li]) { li += 1 }
    }

    private func content(_ l: [Character], from: Int) -> String {
        from < l.count ? String(l[from...]) : ""
    }

    private static func isSeqItem(_ c: String) -> Bool {
        c == "-" || c.hasPrefix("- ")
    }

    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }

    // MARK: - Documento

    private mutating func parseDocument() throws -> JSONValue {
        // direttive e marcatore di inizio documento
        while li < lines.count {
            if isBlankOrComment(lines[li]) { li += 1; continue }
            let c = String(lines[li])
            if c.hasPrefix("%") { li += 1; continue }
            if c == "---" { li += 1; continue }
            if c.hasPrefix("--- ") {
                lines[li] = Array(repeating: " ", count: 4) + Array(c.dropFirst(4))
            }
            break
        }
        return try parseBlockNode(minIndent: 0, scalarParent: -1)
    }

    /// Nodo a blocchi che inizia alla prossima riga significativa con indentazione >= minIndent.
    private mutating func parseBlockNode(minIndent: Int, scalarParent: Int) throws -> JSONValue {
        skipBlank()
        guard li < lines.count else { return .null }
        let line = lines[li]
        let ind = indentOf(line)
        if ind < minIndent { return .null }
        let c = content(line, from: ind)
        if c == "---" || c == "..." { return .null }
        if YAMLParser.isSeqItem(c) { return try parseSequence(indent: ind) }
        if findMappingColon(line, from: ind) != nil { return try parseMapping(indent: ind) }
        li += 1
        return try parseValue(rest: c, parentIndent: scalarParent, allowSameIndentSequence: false)
    }

    /// Posizione dei ':' che separano chiave e valore, oppure nil se la riga non è una coppia chiave/valore.
    private func findMappingColon(_ l: [Character], from start: Int) -> Int? {
        guard start < l.count else { return nil }
        var i = start
        let first = l[i]
        if "[{|>&*!%@`#".contains(first) { return nil }
        if first == "-" && (i + 1 >= l.count || l[i + 1] == " ") { return nil }
        if first == "\"" || first == "'" {
            // chiave quotata
            i += 1
            while i < l.count {
                if first == "\"" && l[i] == "\\" { i += 2; continue }
                if l[i] == first {
                    if first == "'" && i + 1 < l.count && l[i + 1] == "'" { i += 2; continue }
                    break
                }
                i += 1
            }
            guard i < l.count else { return nil }
            i += 1
            while i < l.count, l[i] == " " { i += 1 }
            if i < l.count, l[i] == ":", i + 1 >= l.count || l[i + 1] == " " { return i }
            return nil
        }
        if first == "?" && (i + 1 >= l.count || l[i + 1] == " ") { return nil }
        while i < l.count {
            let ch = l[i]
            if ch == "#" && i > start && l[i - 1] == " " { return nil }
            if ch == ":" && (i + 1 >= l.count || l[i + 1] == " ") { return i }
            i += 1
        }
        return nil
    }

    // MARK: - Collezioni a blocchi

    private mutating func parseMapping(indent: Int) throws -> JSONValue {
        var obj = OrderedObject()
        while true {
            skipBlank()
            guard li < lines.count else { break }
            let line = lines[li]
            let ind = indentOf(line)
            if ind < indent { break }
            if ind > indent { throw err("indentazione inattesa (attesa \(indent), trovata \(ind))") }
            let c = content(line, from: ind)
            if c == "---" || c == "..." { break }
            guard let colon = findMappingColon(line, from: ind) else {
                if YAMLParser.isSeqItem(c) { break }
                throw err("attesa una chiave 'nome: valore', trovato '\(c)'")
            }
            let key = try unquoteKey(YAMLParser.trim(String(line[ind..<colon])))
            let rest = colon + 1 < line.count ? String(line[(colon + 1)...]) : ""
            li += 1
            let value = try parseValue(rest: rest, parentIndent: indent, allowSameIndentSequence: true)
            if key == "<<" {
                let sources = value.arrayValue ?? [value]
                for s in sources {
                    if let o = s.objectValue { for (k, v) in o.pairs where obj[k] == nil { obj[k] = v } }
                }
            } else {
                obj[key] = value
            }
        }
        return .object(obj)
    }

    private mutating func parseSequence(indent: Int) throws -> JSONValue {
        var arr: [JSONValue] = []
        while true {
            skipBlank()
            guard li < lines.count else { break }
            let line = lines[li]
            let ind = indentOf(line)
            if ind != indent { if ind > indent { throw err("indentazione inattesa nella sequenza") }; break }
            let c = content(line, from: ind)
            guard YAMLParser.isSeqItem(c) else { break }
            var p = ind + 1
            while p < line.count, line[p] == " " { p += 1 }
            if p >= line.count || line[p] == "#" {
                li += 1
                skipBlank()
                if li < lines.count, indentOf(lines[li]) > ind {
                    arr.append(try parseBlockNode(minIndent: ind + 1, scalarParent: ind))
                } else {
                    arr.append(.null)
                }
            } else {
                // l'elemento inizia sulla stessa riga: lo trattiamo come un nodo alla colonna p
                lines[li] = Array(repeating: " ", count: p) + Array(line[p...])
                arr.append(try parseBlockNode(minIndent: p, scalarParent: ind))
            }
        }
        return .array(arr)
    }

    // MARK: - Valori

    /// Valore che segue "chiave:" (o "- ") sulla stessa riga; `rest` è il testo grezzo dopo i due punti.
    private mutating func parseValue(rest raw: String, parentIndent: Int, allowSameIndentSequence: Bool) throws -> JSONValue {
        var r = YAMLParser.trim(YAMLParser.stripComment(raw))
        var anchor: String? = nil
        var tag: String? = nil
        while r.hasPrefix("&") || r.hasPrefix("!") {
            let token = String(r.prefix { $0 != " " })
            if token.hasPrefix("&") { anchor = String(token.dropFirst()) } else { tag = token }
            r = YAMLParser.trim(String(r.dropFirst(token.count)))
        }

        var value: JSONValue
        if r.isEmpty {
            skipBlank()
            if li < lines.count {
                let ni = indentOf(lines[li])
                let nc = content(lines[li], from: ni)
                if ni > parentIndent {
                    value = try parseBlockNode(minIndent: parentIndent + 1, scalarParent: parentIndent)
                } else if allowSameIndentSequence && ni == parentIndent && YAMLParser.isSeqItem(nc) {
                    value = try parseSequence(indent: ni)
                } else {
                    value = .null
                }
            } else {
                value = .null
            }
        } else if r.hasPrefix("*") {
            let name = String(r.dropFirst())
            guard let v = anchors[name] else { throw err("alias sconosciuto '*\(name)'") }
            value = v
        } else if r.hasPrefix("|") || r.hasPrefix(">") {
            value = .string(parseBlockScalar(header: r, parentIndent: parentIndent))
        } else if r.hasPrefix("[") || r.hasPrefix("{") {
            value = try parseFlowMultiline(first: r)
        } else if r.hasPrefix("\"") || r.hasPrefix("'") {
            value = .string(try parseQuotedMultiline(first: YAMLParser.trim(raw).dropTags()))
        } else {
            value = YAMLParser.resolvePlain(parsePlainMultiline(first: r, parentIndent: parentIndent))
        }

        if let t = tag {
            switch t {
            case "!!str", "!str":
                if case .string = value {} else { value = .string(value.scalarString ?? value.toJSON(pretty: false)) }
            case "!!int", "!!float":
                value = .number(value.numberValue)
            case "!!bool":
                value = .bool(["true", "yes", "on", "1"].contains(value.stringValue.lowercased()))
            case "!!null":
                value = .null
            default: break
            }
        }
        if let a = anchor { anchors[a] = value }
        return value
    }

    /// Rimuove un commento finale rispettando le stringhe quotate e le collezioni flow.
    static func stripComment(_ s: String) -> String {
        let c = Array(s)
        var start = 0
        while start < c.count, c[start] == " " { start += 1 }
        guard start < c.count else { return s }
        let quoted = c[start] == "\"" || c[start] == "'" || c[start] == "[" || c[start] == "{"
        var inSingle = false, inDouble = false
        var i = start
        while i < c.count {
            let ch = c[i]
            if quoted {
                if inDouble {
                    if ch == "\\" { i += 2; continue }
                    if ch == "\"" { inDouble = false }
                } else if inSingle {
                    if ch == "'" {
                        if i + 1 < c.count, c[i + 1] == "'" { i += 2; continue }
                        inSingle = false
                    }
                } else if ch == "\"" { inDouble = true }
                else if ch == "'" { inSingle = true }
                else if ch == "#" && i > 0 && (c[i - 1] == " " || c[i - 1] == "\t") { return String(c[0..<i]) }
            } else if ch == "#" && (i == start || c[i - 1] == " " || c[i - 1] == "\t") {
                return String(c[0..<i])
            }
            i += 1
        }
        return s
    }

    // MARK: - Scalari plain

    private mutating func parsePlainMultiline(first: String, parentIndent: Int) -> String {
        var out = first
        while li < lines.count {
            // righe vuote: contano come "\n" solo se segue una continuazione
            var blanks = 0
            var j = li
            while j < lines.count, indentOf(lines[j]) >= lines[j].count { blanks += 1; j += 1 }
            guard j < lines.count else { break }
            let l = lines[j]
            let ind = indentOf(l)
            if ind <= parentIndent { break }
            let c = content(l, from: ind)
            if c.hasPrefix("#") { break }
            if findMappingColon(l, from: ind) != nil || YAMLParser.isSeqItem(c) { break }
            let piece = YAMLParser.trim(YAMLParser.stripComment(c))
            out += blanks > 0 ? String(repeating: "\n", count: blanks) + piece : " " + piece
            li = j + 1
        }
        return out
    }

    static func resolvePlain(_ s: String) -> JSONValue {
        switch s {
        case "", "~", "null", "Null", "NULL": return .null
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        case ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF": return .number(.infinity)
        case "-.inf", "-.Inf", "-.INF": return .number(-.infinity)
        case ".nan", ".NaN", ".NAN": return .number(.nan)
        default: break
        }
        let range = NSRange(s.startIndex..., in: s)
        if intPattern.firstMatch(in: s, range: range) != nil, let d = Double(s) { return .number(d) }
        if s.hasPrefix("0x"), let v = UInt64(s.dropFirst(2), radix: 16) { return .number(Double(v)) }
        if s.hasPrefix("0o"), let v = UInt64(s.dropFirst(2), radix: 8) { return .number(Double(v)) }
        if floatPattern.firstMatch(in: s, range: range) != nil, let d = Double(s) { return .number(d) }
        return .string(s)
    }

    private static let intPattern = try! NSRegularExpression(pattern: "^[-+]?[0-9]+$")
    private static let floatPattern = try! NSRegularExpression(pattern: "^[-+]?(\\.[0-9]+|[0-9]+(\\.[0-9]*)?)([eE][-+]?[0-9]+)?$")

    // MARK: - Scalari quotati

    private mutating func parseQuotedMultiline(first: String) throws -> String {
        var chars = Array(first)
        let q = chars[0]
        var pos = 1
        var out = ""
        while true {
            var continuation = false
            while pos < chars.count {
                let ch = chars[pos]
                if q == "'" {
                    if ch == "'" {
                        if pos + 1 < chars.count, chars[pos + 1] == "'" { out.append("'"); pos += 2; continue }
                        return out
                    }
                    out.append(ch); pos += 1
                } else {
                    if ch == "\"" { return out }
                    if ch == "\\" {
                        guard pos + 1 < chars.count else {
                            // "\" a fine riga: continuazione senza spazio
                            pos += 1
                            continuation = true
                            break
                        }
                        let e = chars[pos + 1]
                        pos += 2
                        switch e {
                        case "n": out.append("\n")
                        case "t": out.append("\t")
                        case "r": out.append("\r")
                        case "0": out.append("\0")
                        case "a": out.append("\u{07}")
                        case "b": out.append("\u{08}")
                        case "e": out.append("\u{1B}")
                        case "f": out.append("\u{0C}")
                        case "v": out.append("\u{0B}")
                        case " ": out.append(" ")
                        case "/": out.append("/")
                        case "\"": out.append("\"")
                        case "\\": out.append("\\")
                        case "N": out.append("\u{85}")
                        case "_": out.append("\u{A0}")
                        case "x", "u", "U":
                            let n = e == "x" ? 2 : (e == "u" ? 4 : 8)
                            guard pos + n <= chars.count, let v = UInt32(String(chars[pos..<(pos + n)]), radix: 16),
                                  let sc = Unicode.Scalar(v) else { throw err("escape \\\(e) non valido") }
                            out.unicodeScalars.append(sc)
                            pos += n
                        default:
                            throw err("escape non valido '\\\(e)'")
                        }
                        continue
                    }
                    out.append(ch); pos += 1
                }
            }
            // fine riga senza chiusura: continua sulla riga successiva con folding
            guard li < lines.count else { throw err("stringa quotata non chiusa") }
            if !continuation {
                while out.hasSuffix(" ") || out.hasSuffix("\t") { out.removeLast() }
            }
            var blanks = 0
            while li < lines.count, indentOf(lines[li]) >= lines[li].count { blanks += 1; li += 1 }
            guard li < lines.count else { throw err("stringa quotata non chiusa") }
            if !continuation { out += blanks > 0 ? String(repeating: "\n", count: blanks) : " " }
            let l = lines[li]
            chars = Array(l[indentOf(l)...])
            pos = 0
            li += 1
        }
    }

    private func unquoteKey(_ k: String) throws -> String {
        guard let f = k.first, f == "\"" || f == "'" else { return k }
        var sub = YAMLParser(k)
        sub.li = 1
        return try sub.parseQuotedMultiline(first: k)
    }

    // MARK: - Scalari a blocco

    private mutating func parseBlockScalar(header: String, parentIndent: Int) -> String {
        let style = header.first!
        var chomp: Character = "c"
        var explicit: Int? = nil
        for ch in header.dropFirst() {
            if ch == "-" { chomp = "-" } else if ch == "+" { chomp = "+" }
            else if let d = ch.wholeNumberValue, d > 0 { explicit = d }
            else if ch == " " || ch == "#" { break }
        }
        let base = max(parentIndent, 0)
        var contentIndent: Int? = explicit.map { (parentIndent < 0 ? 0 : base) + $0 }
        var raw: [String] = []
        while li < lines.count {
            let l = lines[li]
            let ind = indentOf(l)
            if ind >= l.count {
                // riga vuota (anche con soli spazi)
                if let ci = contentIndent, l.count > ci { raw.append(String(l[ci...])) } else { raw.append("") }
                li += 1
                continue
            }
            if contentIndent == nil {
                if ind <= parentIndent { break }
                contentIndent = ind
            }
            if ind < contentIndent! { break }
            raw.append(String(l[contentIndent!...]))
            li += 1
        }
        // righe vuote finali
        var trailing = 0
        while let last = raw.last, YAMLParser.trim(last).isEmpty { raw.removeLast(); trailing += 1 }
        // se abbiamo consumato righe vuote che appartengono al nodo successivo non importa: sono vuote
        var text: String
        if style == "|" {
            text = raw.joined(separator: "\n")
        } else {
            text = ""
            var lastNonEmpty: String? = nil
            for (idx, line) in raw.enumerated() {
                if idx == 0 { text = line; if !line.isEmpty { lastNonEmpty = line }; continue }
                let prev = raw[idx - 1]
                if line.isEmpty { text += "\n"; continue }
                if prev.isEmpty {
                    if let lne = lastNonEmpty, !lne.hasPrefix(" "), !line.hasPrefix(" ") { text += line }
                    else { text += "\n" + line }
                } else if line.hasPrefix(" ") || prev.hasPrefix(" ") {
                    text += "\n" + line
                } else {
                    text += " " + line
                }
                lastNonEmpty = line
            }
        }
        switch chomp {
        case "-": return text
        case "+": return raw.isEmpty ? String(repeating: "\n", count: trailing) : text + "\n" + String(repeating: "\n", count: trailing)
        default: return raw.isEmpty ? "" : text + "\n"
        }
    }

    // MARK: - Collezioni flow

    private mutating func parseFlowMultiline(first: String) throws -> JSONValue {
        var text = first
        func depth(_ s: String) -> Int {
            var d = 0
            var inS = false, inD = false
            var prev: Character = " "
            for ch in s {
                if inD { if ch == "\"" && prev != "\\" { inD = false } }
                else if inS { if ch == "'" { inS = false } }
                else if ch == "\"" { inD = true }
                else if ch == "'" { inS = true }
                else if ch == "[" || ch == "{" { d += 1 }
                else if ch == "]" || ch == "}" { d -= 1 }
                prev = ch
            }
            return d
        }
        while depth(text) > 0 {
            guard li < lines.count else { throw err("collezione flow non chiusa") }
            text += " " + YAMLParser.trim(YAMLParser.stripComment(String(lines[li])))
            li += 1
        }
        var fp = FlowParser(text, anchors: anchors, line: li)
        let v = try fp.parseValue()
        return v
    }
}

private extension String {
    /// Rimuove eventuali ancore/tag iniziali (es. `&a "x"`).
    func dropTags() -> String {
        var s = self
        while s.hasPrefix("&") || s.hasPrefix("!") {
            s = String(s.drop { $0 != " " }).trimmingCharacters(in: .whitespaces)
        }
        return s
    }
}

/// Parser delle collezioni flow: [a, b], {k: v}, annidate.
struct FlowParser {
    private let c: [Character]
    private var pos = 0
    private let anchors: [String: JSONValue]
    private let line: Int

    init(_ text: String, anchors: [String: JSONValue], line: Int) {
        c = Array(text)
        self.anchors = anchors
        self.line = line
    }

    private func err(_ m: String) -> YAMLError { YAMLError(message: m, line: line) }

    private mutating func ws() { while pos < c.count, c[pos] == " " || c[pos] == "\t" || c[pos] == "\n" { pos += 1 } }

    mutating func parseValue() throws -> JSONValue {
        ws()
        guard pos < c.count else { return .null }
        switch c[pos] {
        case "[": return try parseSeq()
        case "{": return try parseMap()
        case "\"", "'": return .string(try parseQuoted())
        case "*":
            pos += 1
            var name = ""
            while pos < c.count, !",]} ".contains(c[pos]) { name.append(c[pos]); pos += 1 }
            guard let v = anchors[name] else { throw err("alias sconosciuto '*\(name)'") }
            return v
        default:
            return YAMLParser.resolvePlain(parsePlain())
        }
    }

    private mutating func parsePlain() -> String {
        var s = ""
        while pos < c.count {
            let ch = c[pos]
            if ch == "," || ch == "]" || ch == "}" { break }
            if ch == ":" && (pos + 1 >= c.count || ",]} ".contains(c[pos + 1])) { break }
            s.append(ch)
            pos += 1
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private mutating func parseQuoted() throws -> String {
        let q = c[pos]
        pos += 1
        var out = ""
        while pos < c.count {
            let ch = c[pos]
            if q == "'" {
                if ch == "'" {
                    if pos + 1 < c.count, c[pos + 1] == "'" { out.append("'"); pos += 2; continue }
                    pos += 1
                    return out
                }
            } else {
                if ch == "\"" { pos += 1; return out }
                if ch == "\\", pos + 1 < c.count {
                    let e = c[pos + 1]
                    pos += 2
                    switch e {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "/": out.append("/")
                    case "0": out.append("\0")
                    case "u", "x", "U":
                        let n = e == "x" ? 2 : (e == "u" ? 4 : 8)
                        if pos + n <= c.count, let v = UInt32(String(c[pos..<(pos + n)]), radix: 16), let sc = Unicode.Scalar(v) {
                            out.unicodeScalars.append(sc)
                        }
                        pos += n
                    default: out.append(e)
                    }
                    continue
                }
            }
            out.append(ch)
            pos += 1
        }
        throw err("stringa quotata non chiusa")
    }

    private mutating func parseSeq() throws -> JSONValue {
        pos += 1
        var arr: [JSONValue] = []
        while true {
            ws()
            guard pos < c.count else { throw err("']' mancante") }
            if c[pos] == "]" { pos += 1; return .array(arr) }
            let item = try parseValue()
            ws()
            if pos < c.count, c[pos] == ":" {
                // coppia singola dentro una sequenza: [a: 1]
                pos += 1
                let v = try parseValue()
                arr.append(.object(OrderedObject([(item.stringValue, v)])))
                ws()
            } else {
                arr.append(item)
            }
            guard pos < c.count else { throw err("']' mancante") }
            if c[pos] == "," { pos += 1; continue }
            if c[pos] == "]" { pos += 1; return .array(arr) }
            throw err("atteso ',' o ']' nella sequenza flow")
        }
    }

    private mutating func parseMap() throws -> JSONValue {
        pos += 1
        var obj = OrderedObject()
        while true {
            ws()
            guard pos < c.count else { throw err("'}' mancante") }
            if c[pos] == "}" { pos += 1; return .object(obj) }
            let keyValue: JSONValue
            if c[pos] == "\"" || c[pos] == "'" { keyValue = .string(try parseQuoted()) } else { keyValue = .string(parsePlain()) }
            ws()
            var value: JSONValue = .null
            if pos < c.count, c[pos] == ":" {
                pos += 1
                value = try parseValue()
                ws()
            }
            let key = keyValue.stringValue
            if key == "<<", let o = value.objectValue {
                for (k, v) in o.pairs where obj[k] == nil { obj[k] = v }
            } else {
                obj[key] = value
            }
            guard pos < c.count else { throw err("'}' mancante") }
            if c[pos] == "," { pos += 1; continue }
            if c[pos] == "}" { pos += 1; return .object(obj) }
            throw err("atteso ',' o '}' nella mappa flow")
        }
    }
}
