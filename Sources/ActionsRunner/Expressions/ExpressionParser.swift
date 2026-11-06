import Foundation

/// AST delle espressioni `${{ }}` di GitHub Actions.
indirect enum Expr {
    case literal(JSONValue)
    case context(String)
    case member(Expr, String)
    case index(Expr, Expr)
    case wildcard(Expr)
    case call(String, [Expr])
    case not(Expr)
    case compare(String, Expr, Expr)   // == != < <= > >=
    case and(Expr, Expr)
    case or(Expr, Expr)

    /// true se l'espressione invoca una funzione di stato (success/failure/cancelled/always).
    var containsStatusFunction: Bool {
        switch self {
        case .literal, .context: return false
        case .member(let e, _), .wildcard(let e), .not(let e): return e.containsStatusFunction
        case .index(let a, let b), .compare(_, let a, let b), .and(let a, let b), .or(let a, let b):
            return a.containsStatusFunction || b.containsStatusFunction
        case .call(let name, let args):
            if ExpressionFunctions.statusFunctions.contains(name.lowercased()) { return true }
            return args.contains { $0.containsStatusFunction }
        }
    }
}

struct ExpressionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ExprToken: Equatable {
    case number(Double)
    case string(String)
    case ident(String)
    case punct(String)
    case eof
}

struct ExpressionLexer {
    private let chars: [Character]
    private var pos = 0

    init(_ text: String) { chars = Array(text) }

    mutating func tokenize() throws -> [ExprToken] {
        var tokens: [ExprToken] = []
        while true {
            skipWhitespace()
            guard pos < chars.count else { tokens.append(.eof); return tokens }
            let c = chars[pos]
            if c == "'" {
                tokens.append(.string(try readString()))
            } else if c.isNumber || (c == "-" && pos + 1 < chars.count && (chars[pos + 1].isNumber || chars[pos + 1] == ".") && expectsValue(tokens)) ||
                        (c == "." && pos + 1 < chars.count && chars[pos + 1].isNumber && expectsValue(tokens)) {
                tokens.append(.number(try readNumber()))
            } else if c.isLetter || c == "_" {
                tokens.append(.ident(readIdent()))
            } else {
                let two = pos + 1 < chars.count ? String([c, chars[pos + 1]]) : ""
                if ["==", "!=", "<=", ">=", "&&", "||"].contains(two) {
                    tokens.append(.punct(two)); pos += 2
                } else if "<>!()[].,*".contains(c) {
                    tokens.append(.punct(String(c))); pos += 1
                } else {
                    throw ExpressionError(message: "Carattere inatteso '\(c)' in posizione \(pos)")
                }
            }
        }
    }

    private func expectsValue(_ tokens: [ExprToken]) -> Bool {
        guard let last = tokens.last else { return true }
        switch last {
        case .punct(let p): return p != ")" && p != "]" && p != "*"
        default: return false
        }
    }

    private mutating func skipWhitespace() {
        while pos < chars.count, chars[pos].isWhitespace { pos += 1 }
    }

    private mutating func readString() throws -> String {
        pos += 1
        var s = ""
        while pos < chars.count {
            if chars[pos] == "'" {
                if pos + 1 < chars.count, chars[pos + 1] == "'" { s.append("'"); pos += 2; continue }
                pos += 1
                return s
            }
            s.append(chars[pos]); pos += 1
        }
        throw ExpressionError(message: "Stringa non terminata")
    }

    private mutating func readNumber() throws -> Double {
        let start = pos
        if chars[pos] == "-" { pos += 1 }
        if pos + 1 < chars.count, chars[pos] == "0", chars[pos + 1] == "x" || chars[pos + 1] == "X" {
            pos += 2
            while pos < chars.count, chars[pos].isHexDigit { pos += 1 }
        } else {
            while pos < chars.count {
                let c = chars[pos]
                if c.isNumber || c == "." { pos += 1; continue }
                if c == "e" || c == "E" {
                    pos += 1
                    if pos < chars.count, chars[pos] == "+" || chars[pos] == "-" { pos += 1 }
                    continue
                }
                break
            }
        }
        let text = String(chars[start..<pos])
        let value = JSONValue.parseNumber(text)
        if value.isNaN { throw ExpressionError(message: "Numero non valido '\(text)'") }
        return value
    }

    private mutating func readIdent() -> String {
        let start = pos
        while pos < chars.count, chars[pos].isLetter || chars[pos].isNumber || chars[pos] == "_" || chars[pos] == "-" { pos += 1 }
        return String(chars[start..<pos])
    }
}

/// Parser a discesa ricorsiva. Precedenza (alta → bassa):
/// () [] . → ! → < <= > >= → == != → && → ||
struct ExpressionParser {
    private var tokens: [ExprToken]
    private var pos = 0

    static func parse(_ text: String) throws -> Expr {
        var lexer = ExpressionLexer(text)
        var parser = ExpressionParser(tokens: try lexer.tokenize())
        let expr = try parser.parseOr()
        guard parser.peek == .eof else {
            throw ExpressionError(message: "Token inatteso \(parser.describe(parser.peek))")
        }
        return expr
    }

    private init(tokens: [ExprToken]) { self.tokens = tokens }

    private var peek: ExprToken { tokens[pos] }

    private mutating func advance() -> ExprToken {
        let t = tokens[pos]
        if pos < tokens.count - 1 { pos += 1 }
        return t
    }

    private func describe(_ t: ExprToken) -> String {
        switch t {
        case .number(let d): return "'\(JSONValue.formatNumber(d))'"
        case .string(let s): return "'\(s)'"
        case .ident(let s): return "'\(s)'"
        case .punct(let p): return "'\(p)'"
        case .eof: return "fine espressione"
        }
    }

    private mutating func expect(_ p: String) throws {
        guard case .punct(p) = peek else { throw ExpressionError(message: "Atteso '\(p)' ma trovato \(describe(peek))") }
        _ = advance()
    }

    private mutating func parseOr() throws -> Expr {
        var left = try parseAnd()
        while peek == .punct("||") { _ = advance(); left = .or(left, try parseAnd()) }
        return left
    }

    private mutating func parseAnd() throws -> Expr {
        var left = try parseEquality()
        while peek == .punct("&&") { _ = advance(); left = .and(left, try parseEquality()) }
        return left
    }

    private mutating func parseEquality() throws -> Expr {
        var left = try parseComparison()
        while case .punct(let p) = peek, p == "==" || p == "!=" {
            _ = advance()
            left = .compare(p, left, try parseComparison())
        }
        return left
    }

    private mutating func parseComparison() throws -> Expr {
        var left = try parseUnary()
        while case .punct(let p) = peek, ["<", "<=", ">", ">="].contains(p) {
            _ = advance()
            left = .compare(p, left, try parseUnary())
        }
        return left
    }

    private mutating func parseUnary() throws -> Expr {
        if peek == .punct("!") { _ = advance(); return .not(try parseUnary()) }
        return try parsePostfix()
    }

    private mutating func parsePostfix() throws -> Expr {
        var expr = try parsePrimary()
        while true {
            if peek == .punct(".") {
                _ = advance()
                switch advance() {
                case .ident(let name): expr = .member(expr, name)
                case .punct("*"): expr = .wildcard(expr)
                case .number(let d):
                    // es. "steps.a.outputs.1abc" non è valido, ma ".0" viene tokenizzato come numero
                    expr = .member(expr, JSONValue.formatNumber(d))
                case let t: throw ExpressionError(message: "Atteso nome di proprietà dopo '.', trovato \(describe(t))")
                }
            } else if peek == .punct("[") {
                _ = advance()
                if peek == .punct("*") {
                    _ = advance()
                    try expect("]")
                    expr = .wildcard(expr)
                } else {
                    let index = try parseOr()
                    try expect("]")
                    expr = .index(expr, index)
                }
            } else {
                return expr
            }
        }
    }

    private mutating func parsePrimary() throws -> Expr {
        let t = advance()
        switch t {
        case .number(let d): return .literal(.number(d))
        case .string(let s): return .literal(.string(s))
        case .punct("("):
            let e = try parseOr()
            try expect(")")
            return e
        case .ident(let name):
            switch name {
            case "true": return .literal(.bool(true))
            case "false": return .literal(.bool(false))
            case "null": return .literal(.null)
            case "NaN": return .literal(.number(.nan))
            case "Infinity": return .literal(.number(.infinity))
            default: break
            }
            if peek == .punct("(") {
                _ = advance()
                var args: [Expr] = []
                if peek != .punct(")") {
                    args.append(try parseOr())
                    while peek == .punct(",") { _ = advance(); args.append(try parseOr()) }
                }
                try expect(")")
                try ExpressionFunctions.validateArity(name, args.count)
                return .call(name, args)
            }
            return .context(name)
        default:
            throw ExpressionError(message: "Token inatteso \(describe(t))")
        }
    }
}
