import Foundation

/// Stato usato dalle funzioni success()/failure()/cancelled()/always().
struct StatusState {
    var succeeded: Bool = true
    var failed: Bool = false
    var cancelled: Bool = false
}

/// Contesto di valutazione: contesti nominati + callback per hashFiles e stato.
struct EvaluationContext {
    var contexts: [String: JSONValue] = [:]
    var status = StatusState()
    var hashFiles: (([String]) -> String)? = nil

    subscript(name: String) -> JSONValue? {
        get { contexts[name.lowercased()] }
        set { contexts[name.lowercased()] = newValue }
    }
}

enum ExpressionEvaluator {
    private struct Result {
        var value: JSONValue
        var isFilter: Bool = false
    }

    static func evaluate(_ expr: Expr, _ ctx: EvaluationContext) throws -> JSONValue {
        try eval(expr, ctx).value
    }

    static func evaluate(_ text: String, _ ctx: EvaluationContext) throws -> JSONValue {
        try evaluate(try ExpressionParser.parse(text), ctx)
    }

    private static func eval(_ expr: Expr, _ ctx: EvaluationContext) throws -> Result {
        switch expr {
        case .literal(let v):
            return Result(value: v)

        case .context(let name):
            guard let v = ctx[name] else {
                throw ExpressionError(message: "Contesto non riconosciuto: '\(name)'. Contesti disponibili: \(ctx.contexts.keys.sorted().joined(separator: ", "))")
            }
            return Result(value: v)

        case .member(let baseExpr, let name):
            let base = try eval(baseExpr, ctx)
            if base.isFilter {
                var out: [JSONValue] = []
                for item in base.value.arrayValue ?? [] {
                    if let o = item.objectValue, let v = o.lookup(name) { out.append(v) }
                }
                return Result(value: .array(out), isFilter: true)
            }
            return Result(value: base.value[name] ?? .null)

        case .index(let baseExpr, let indexExpr):
            let base = try eval(baseExpr, ctx)
            let index = try eval(indexExpr, ctx).value
            if base.isFilter {
                var out: [JSONValue] = []
                for item in base.value.arrayValue ?? [] {
                    let v = lookupIndex(item, index)
                    if !v.isNull { out.append(v) }
                }
                return Result(value: .array(out), isFilter: true)
            }
            return Result(value: lookupIndex(base.value, index))

        case .wildcard(let baseExpr):
            let base = try eval(baseExpr, ctx)
            if base.isFilter {
                var out: [JSONValue] = []
                for item in base.value.arrayValue ?? [] { out.append(contentsOf: children(item)) }
                return Result(value: .array(out), isFilter: true)
            }
            return Result(value: .array(children(base.value)), isFilter: true)

        case .call(let name, let args):
            return Result(value: try ExpressionFunctions.call(name, args, ctx))

        case .not(let e):
            let inner = try eval(e, ctx).value
            return Result(value: .bool(!inner.isTruthy))

        case .and(let a, let b):
            let left = try eval(a, ctx).value
            if !left.isTruthy { return Result(value: left) }
            return Result(value: try eval(b, ctx).value)

        case .or(let a, let b):
            let left = try eval(a, ctx).value
            if left.isTruthy { return Result(value: left) }
            return Result(value: try eval(b, ctx).value)

        case .compare(let op, let a, let b):
            let l = try eval(a, ctx).value
            let r = try eval(b, ctx).value
            return Result(value: .bool(compare(op, l, r)))
        }
    }

    private static func children(_ v: JSONValue) -> [JSONValue] {
        switch v {
        case .array(let a): return a
        case .object(let o): return o.values
        default: return []
        }
    }

    private static func lookupIndex(_ base: JSONValue, _ index: JSONValue) -> JSONValue {
        switch base {
        case .array(let a):
            let n = index.numberValue
            guard !n.isNaN, n >= 0, n == n.rounded(), Int(n) < a.count else { return .null }
            return a[Int(n)]
        case .object(let o):
            return o.lookup(index.stringValue) ?? .null
        default:
            return .null
        }
    }

    // MARK: Uguaglianza e confronto (regole "loose" di GitHub)

    static func looseEquals(_ l: JSONValue, _ r: JSONValue) -> Bool {
        switch (l, r) {
        case (.null, .null): return true
        case (.string(let a), .string(let b)): return a.caseInsensitiveCompare(b) == .orderedSame
        case (.bool(let a), .bool(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.array, _), (.object, _), (_, .array), (_, .object):
            return false // uguali solo se stessa istanza
        default:
            let a = l.numberValue, b = r.numberValue
            if a.isNaN || b.isNaN { return false }
            return a == b
        }
    }

    static func compare(_ op: String, _ l: JSONValue, _ r: JSONValue) -> Bool {
        switch op {
        case "==": return looseEquals(l, r)
        case "!=": return !looseEquals(l, r)
        default: break
        }
        if case .string(let a) = l, case .string(let b) = r {
            let res = a.uppercased().compare(b.uppercased(), options: .literal)
            switch op {
            case "<": return res == .orderedAscending
            case "<=": return res != .orderedDescending
            case ">": return res == .orderedDescending
            case ">=": return res != .orderedAscending
            default: return false
            }
        }
        let a = l.numberValue, b = r.numberValue
        if a.isNaN || b.isNaN { return false }
        switch op {
        case "<": return a < b
        case "<=": return a <= b
        case ">": return a > b
        case ">=": return a >= b
        default: return false
        }
    }
}

enum ExpressionFunctions {
    static let statusFunctions: Set<String> = ["success", "failure", "cancelled", "always"]

    static let arity: [String: (Int, Int)] = [
        "contains": (2, 2), "startswith": (2, 2), "endswith": (2, 2),
        "format": (1, 255), "join": (1, 2), "tojson": (1, 1), "fromjson": (1, 1),
        "hashfiles": (1, 255), "case": (3, 255),
        "success": (0, 0), "failure": (0, 0), "cancelled": (0, 0), "always": (0, 0)
    ]

    static func validateArity(_ name: String, _ count: Int) throws {
        guard let range = arity[name.lowercased()] else {
            throw ExpressionError(message: "Funzione sconosciuta '\(name)'")
        }
        let lo = range.0, hi = range.1
        if count < lo || count > hi {
            let expected = lo == hi ? "\(lo)" : "\(lo)-\(hi)"
            throw ExpressionError(message: "Numero di argomenti errato per '\(name)': \(count) (attesi \(expected))")
        }
        if name.lowercased() == "case" && count % 2 == 0 {
            throw ExpressionError(message: "case() richiede un numero dispari di argomenti (coppie predicato/valore + default)")
        }
    }

    static func call(_ rawName: String, _ args: [Expr], _ ctx: EvaluationContext) throws -> JSONValue {
        let name = rawName.lowercased()
        func arg(_ i: Int) throws -> JSONValue { try ExpressionEvaluator.evaluate(args[i], ctx) }

        switch name {
        case "success":
            return .bool(ctx.status.succeeded && !ctx.status.cancelled)
        case "failure":
            return .bool(ctx.status.failed && !ctx.status.cancelled)
        case "cancelled":
            return .bool(ctx.status.cancelled)
        case "always":
            return .bool(true)

        case "contains":
            let search = try arg(0), item = try arg(1)
            if case .array(let a) = search {
                return .bool(a.contains { ExpressionEvaluator.looseEquals($0, item) })
            }
            return .bool(search.stringValue.lowercased().contains(item.stringValue.lowercased()))

        case "startswith":
            return .bool(try arg(0).stringValue.lowercased().hasPrefix(try arg(1).stringValue.lowercased()))

        case "endswith":
            return .bool(try arg(0).stringValue.lowercased().hasSuffix(try arg(1).stringValue.lowercased()))

        case "format":
            let fmt = try arg(0).stringValue
            var values: [String] = []
            var i = 1
            while i < args.count { values.append(try arg(i).stringValue); i += 1 }
            return .string(try format(fmt, values))

        case "join":
            let v = try arg(0)
            var sep = ","
            if args.count > 1 { sep = try arg(1).stringValue }
            if case .array(let a) = v { return .string(a.map { $0.stringValue }.joined(separator: sep)) }
            return .string(v.stringValue)

        case "tojson":
            return .string(try arg(0).toJSON(pretty: true))

        case "fromjson":
            let s = try arg(0).stringValue
            do { return try JSONValue.parse(json: s) } catch {
                throw ExpressionError(message: "fromJSON: \(error.localizedDescription) — input: \(s.prefix(200))")
            }

        case "hashfiles":
            var patterns: [String] = []
            for i in 0..<args.count { patterns.append(try arg(i).stringValue) }
            return .string(ctx.hashFiles?(patterns) ?? "")

        case "case":
            var i = 0
            while i + 1 < args.count {
                let pred = try arg(i)
                guard case .bool(let b) = pred else {
                    throw ExpressionError(message: "case(): il predicato \(i / 2 + 1) deve essere booleano, trovato \(pred.typeName)")
                }
                if b { return try arg(i + 1) }
                i += 2
            }
            return try arg(args.count - 1)

        default:
            throw ExpressionError(message: "Funzione sconosciuta '\(rawName)'")
        }
    }

    /// format('{0} {{lit}}', a) — '{{' e '}}' producono graffe letterali.
    static func format(_ fmt: String, _ values: [String]) throws -> String {
        let chars = Array(fmt)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "{" {
                if i + 1 < chars.count, chars[i + 1] == "{" { out.append("{"); i += 2; continue }
                var j = i + 1
                var digits = ""
                while j < chars.count, chars[j].isNumber { digits.append(chars[j]); j += 1 }
                guard j < chars.count, chars[j] == "}", let idx = Int(digits) else {
                    throw ExpressionError(message: "format(): stringa di formato non valida '\(fmt)'")
                }
                guard idx < values.count else {
                    throw ExpressionError(message: "format(): indice {\(idx)} oltre il numero di argomenti")
                }
                out += values[idx]
                i = j + 1
            } else if c == "}" {
                if i + 1 < chars.count, chars[i + 1] == "}" { out.append("}"); i += 2; continue }
                throw ExpressionError(message: "format(): '}' non bilanciata in '\(fmt)'")
            } else {
                out.append(c); i += 1
            }
        }
        return out
    }
}

/// Gestione di stringhe con `${{ ... }}` (template).
enum ExpressionTemplate {
    /// Estrae il testo delle espressioni contenute in una stringa.
    static func extractExpressions(_ text: String) -> [String] {
        segments(text).compactMap { if case .expression(let e) = $0 { return e } else { return nil } }
    }

    enum Segment {
        case literal(String)
        case expression(String)
    }

    static func segments(_ text: String) -> [Segment] {
        var result: [Segment] = []
        let chars = Array(text)
        var i = 0
        var literal = ""
        while i < chars.count {
            if chars[i] == "$", i + 2 < chars.count, chars[i + 1] == "{", chars[i + 2] == "{" {
                // cerca la chiusura '}}' rispettando le stringhe tra apici
                var j = i + 3
                var inString = false
                var found = -1
                while j < chars.count {
                    if chars[j] == "'" {
                        if inString, j + 1 < chars.count, chars[j + 1] == "'" { j += 2; continue }
                        inString.toggle()
                    } else if !inString, chars[j] == "}", j + 1 < chars.count, chars[j + 1] == "}" {
                        found = j; break
                    }
                    j += 1
                }
                if found < 0 { literal.append(contentsOf: chars[i...]); break }
                if !literal.isEmpty { result.append(.literal(literal)); literal = "" }
                result.append(.expression(String(chars[(i + 3)..<found]).trimmingCharacters(in: .whitespacesAndNewlines)))
                i = found + 2
            } else {
                literal.append(chars[i]); i += 1
            }
        }
        if !literal.isEmpty { result.append(.literal(literal)) }
        return result
    }

    /// Valuta un template. Se la stringa è una singola espressione, restituisce il valore grezzo
    /// (oggetti/array/numeri inclusi), altrimenti concatena le conversioni a stringa.
    static func evaluate(_ text: String, _ ctx: EvaluationContext) throws -> JSONValue {
        let segs = segments(text)
        if segs.count == 1, case .expression(let e) = segs[0] {
            return try ExpressionEvaluator.evaluate(e, ctx)
        }
        var out = ""
        for seg in segs {
            switch seg {
            case .literal(let s): out += s
            case .expression(let e): out += try ExpressionEvaluator.evaluate(e, ctx).stringValue
            }
        }
        return .string(out)
    }

    static func evaluateString(_ text: String, _ ctx: EvaluationContext) throws -> String {
        let v = try evaluate(text, ctx)
        if case .string(let s) = v { return s }
        return v.stringValue
    }

    /// Valuta ricorsivamente i template in un valore YAML.
    static func evaluateDeep(_ value: JSONValue, _ ctx: EvaluationContext) throws -> JSONValue {
        switch value {
        case .string(let s):
            if s.contains("${{") { return try evaluate(s, ctx) }
            return value
        case .array(let a):
            return .array(try a.map { try evaluateDeep($0, ctx) })
        case .object(let o):
            var out = OrderedObject()
            for (k, v) in o.pairs {
                var key = k
                if k.contains("${{") { key = try evaluateString(k, ctx) }
                out[key] = try evaluateDeep(v, ctx)
            }
            return .object(out)
        default:
            return value
        }
    }

    /// Valuta una condizione `if:`. Se non contiene funzioni di stato viene implicitamente
    /// combinata con `success()` come fa GitHub.
    static func evaluateCondition(_ condition: String?, _ ctx: EvaluationContext) throws -> Bool {
        guard let raw = condition?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return ctx.status.succeeded && !ctx.status.cancelled
        }
        var exprs: [Expr] = []
        let result: JSONValue
        if raw.contains("${{") {
            let segs = segments(raw)
            let onlyExpr = segs.count == 1
            for case .expression(let e) in segs { exprs.append(try ExpressionParser.parse(e)) }
            if onlyExpr, let e = exprs.first {
                result = try ExpressionEvaluator.evaluate(e, ctx)
            } else {
                result = try evaluate(raw, ctx)
            }
        } else {
            let e = try ExpressionParser.parse(raw)
            exprs = [e]
            result = try ExpressionEvaluator.evaluate(e, ctx)
        }
        let hasStatus = exprs.contains { $0.containsStatusFunction }
        if !hasStatus {
            guard ctx.status.succeeded && !ctx.status.cancelled else { return false }
        }
        return result.isTruthy
    }
}
