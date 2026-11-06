import Foundation

/// Oggetto JSON che preserva l'ordine delle chiavi (necessario per matrix, env, jobs...).
struct OrderedObject: Equatable {
    private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    init() {}

    init(_ pairs: [(String, JSONValue)]) {
        for (k, v) in pairs { self[k] = v }
    }

    subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let value = newValue {
                if storage[key] == nil { keys.append(key) }
                storage[key] = value
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    /// Le chiavi dei contesti GitHub sono case-insensitive.
    func lookup(_ key: String) -> JSONValue? {
        if let v = storage[key] { return v }
        let lower = key.lowercased()
        for k in keys where k.lowercased() == lower { return storage[k] }
        return nil
    }

    var pairs: [(key: String, value: JSONValue)] { keys.map { (key: $0, value: storage[$0]!) } }
    var values: [JSONValue] { keys.map { storage[$0]! } }
    var count: Int { keys.count }
    var isEmpty: Bool { keys.isEmpty }

    mutating func merge(_ other: OrderedObject) {
        for (k, v) in other.pairs { self[k] = v }
    }

    func merging(_ other: OrderedObject) -> OrderedObject {
        var copy = self
        copy.merge(other)
        return copy
    }
}

/// Valore dinamico usato per YAML, contesti e risultati delle espressioni.
enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(OrderedObject)

    // MARK: Accesso

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o.lookup(key) }
        return nil
    }

    var objectValue: OrderedObject? {
        if case .object(let o) = self { return o }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Stringa se il valore è scalare (senza conversioni per oggetti/array).
    var scalarString: String? {
        switch self {
        case .string(let s): return s
        case .number, .bool, .null: return stringValue
        default: return nil
        }
    }

    // MARK: Conversioni secondo le regole delle espressioni GitHub

    /// Conversione a stringa: null -> '', bool -> 'true'/'false', array -> 'Array', object -> 'Object'.
    var stringValue: String {
        switch self {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .number(let d): return JSONValue.formatNumber(d)
        case .string(let s): return s
        case .array: return "Array"
        case .object: return "Object"
        }
    }

    /// Falsy: false, 0, -0, "", null, NaN. Tutto il resto è truthy (incluso array/oggetti).
    var isTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .number(let d): return !(d == 0 || d.isNaN)
        case .string(let s): return !s.isEmpty
        case .array, .object: return true
        }
    }

    /// Conversione a numero: null->0, bool->1/0, stringa->numero JSON (vuota=0, invalida=NaN), array/oggetti->NaN.
    var numberValue: Double {
        switch self {
        case .null: return 0
        case .bool(let b): return b ? 1 : 0
        case .number(let d): return d
        case .string(let s): return JSONValue.parseNumber(s)
        case .array, .object: return .nan
        }
    }

    static func parseNumber(_ raw: String) -> Double {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return 0 }
        let lower = s.lowercased()
        if lower == "infinity" || lower == "+infinity" { return .infinity }
        if lower == "-infinity" { return -.infinity }
        if lower == "nan" { return .nan }
        if lower.hasPrefix("0x"), let v = UInt64(lower.dropFirst(2), radix: 16) { return Double(v) }
        if lower.hasPrefix("0o"), let v = UInt64(lower.dropFirst(2), radix: 8) { return Double(v) }
        // Formato JSON (con +/- iniziale tollerato)
        let pattern = "^[-+]?(\\d+\\.?\\d*|\\.\\d+)([eE][-+]?\\d+)?$"
        if s.range(of: pattern, options: .regularExpression) != nil, let d = Double(s) { return d }
        return .nan
    }

    static func formatNumber(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        var s = String(d)
        if s.hasSuffix(".0") { s.removeLast(2) }
        return s
    }

    var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case .number: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    // MARK: JSON

    func toJSON(pretty: Bool = true, indent: Int = 0) -> String {
        let pad = pretty ? String(repeating: "  ", count: indent + 1) : ""
        let closePad = pretty ? String(repeating: "  ", count: indent) : ""
        let nl = pretty ? "\n" : ""
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let d):
            if d.isNaN || d.isInfinite { return "null" }
            return JSONValue.formatNumber(d)
        case .string(let s): return JSONValue.quote(s)
        case .array(let a):
            if a.isEmpty { return "[]" }
            let items = a.map { pad + $0.toJSON(pretty: pretty, indent: indent + 1) }
            return "[" + nl + items.joined(separator: "," + nl) + nl + closePad + "]"
        case .object(let o):
            if o.isEmpty { return "{}" }
            let sep = pretty ? ": " : ":"
            let items = o.pairs.map { pad + JSONValue.quote($0.key) + sep + $0.value.toJSON(pretty: pretty, indent: indent + 1) }
            return "{" + nl + items.joined(separator: "," + nl) + nl + closePad + "}"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func parse(json: String) throws -> JSONValue {
        var parser = JSONTextParser(Array(json.utf8))
        return try parser.parseDocument()
    }

    static func from(any: Any?) -> JSONValue {
        guard let any = any else { return .null }
        if any is NSNull { return .null }
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        }
        if let s = any as? String { return .string(s) }
        if let b = any as? Bool { return .bool(b) }
        if let i = any as? Int { return .number(Double(i)) }
        if let d = any as? Double { return .number(d) }
        if let a = any as? [Any] { return .array(a.map { from(any: $0) }) }
        if let d = any as? [String: Any] {
            var o = OrderedObject()
            for k in d.keys.sorted() { o[k] = from(any: d[k]) }
            return .object(o)
        }
        return .string(String(describing: any))
    }

    /// Converte in Any per JSONSerialization (body delle richieste REST).
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let d): return d == d.rounded() && abs(d) < 1e15 ? Int(d) as Any : d as Any
        case .string(let s): return s
        case .array(let a): return a.map { $0.anyValue }
        case .object(let o):
            var d: [String: Any] = [:]
            for (k, v) in o.pairs { d[k] = v.anyValue }
            return d
        }
    }
}

/// Parser JSON che preserva l'ordine delle chiavi (usato da fromJSON()).
struct JSONTextParser {
    enum ParseError: LocalizedError {
        case unexpected(String, Int)
        var errorDescription: String? {
            switch self {
            case .unexpected(let m, let p): return "JSON non valido: \(m) (posizione \(p))"
            }
        }
    }

    private let bytes: [UInt8]
    private var pos = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func parseDocument() throws -> JSONValue {
        skipWS()
        let v = try parseValue()
        skipWS()
        if pos != bytes.count { throw ParseError.unexpected("caratteri in eccesso", pos) }
        return v
    }

    private mutating func skipWS() {
        while pos < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[pos]) { pos += 1 }
    }

    private mutating func parseValue() throws -> JSONValue {
        skipWS()
        guard pos < bytes.count else { throw ParseError.unexpected("fine inattesa", pos) }
        switch bytes[pos] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return try parseNumber()
        }
    }

    private mutating func expect(_ word: String) throws {
        let w = Array(word.utf8)
        guard pos + w.count <= bytes.count, Array(bytes[pos..<pos + w.count]) == w else {
            throw ParseError.unexpected("atteso \(word)", pos)
        }
        pos += w.count
    }

    private mutating func parseObject() throws -> JSONValue {
        pos += 1
        var o = OrderedObject()
        skipWS()
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "}") { pos += 1; return .object(o) }
        while true {
            skipWS()
            guard pos < bytes.count, bytes[pos] == UInt8(ascii: "\"") else { throw ParseError.unexpected("attesa chiave", pos) }
            let key = try parseString()
            skipWS()
            guard pos < bytes.count, bytes[pos] == UInt8(ascii: ":") else { throw ParseError.unexpected("atteso ':'", pos) }
            pos += 1
            o[key] = try parseValue()
            skipWS()
            guard pos < bytes.count else { throw ParseError.unexpected("fine inattesa", pos) }
            if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
            if bytes[pos] == UInt8(ascii: "}") { pos += 1; return .object(o) }
            throw ParseError.unexpected("atteso ',' o '}'", pos)
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        pos += 1
        var a: [JSONValue] = []
        skipWS()
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array(a) }
        while true {
            a.append(try parseValue())
            skipWS()
            guard pos < bytes.count else { throw ParseError.unexpected("fine inattesa", pos) }
            if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
            if bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array(a) }
            throw ParseError.unexpected("atteso ',' o ']'", pos)
        }
    }

    private mutating func parseString() throws -> String {
        pos += 1
        var out: [UInt8] = []
        while pos < bytes.count {
            let c = bytes[pos]
            if c == UInt8(ascii: "\"") { pos += 1; return String(decoding: out, as: UTF8.self) }
            if c == UInt8(ascii: "\\") {
                pos += 1
                guard pos < bytes.count else { break }
                let e = bytes[pos]
                switch e {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "u"):
                    guard pos + 4 < bytes.count,
                          let code = UInt32(String(decoding: bytes[(pos + 1)...(pos + 4)], as: UTF8.self), radix: 16) else {
                        throw ParseError.unexpected("escape \\u non valido", pos)
                    }
                    pos += 4
                    var scalarValue = code
                    if (0xD800...0xDBFF).contains(code), pos + 6 < bytes.count,
                       bytes[pos + 1] == UInt8(ascii: "\\"), bytes[pos + 2] == UInt8(ascii: "u"),
                       let low = UInt32(String(decoding: bytes[(pos + 3)...(pos + 6)], as: UTF8.self), radix: 16),
                       (0xDC00...0xDFFF).contains(low) {
                        scalarValue = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        pos += 6
                    }
                    let scalar = Unicode.Scalar(scalarValue) ?? "\u{FFFD}"
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default: out.append(e)
                }
                pos += 1
                continue
            }
            out.append(c)
            pos += 1
        }
        throw ParseError.unexpected("stringa non terminata", pos)
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = pos
        while pos < bytes.count {
            let c = bytes[pos]
            if (c >= 0x30 && c <= 0x39) || c == UInt8(ascii: "-") || c == UInt8(ascii: "+") ||
                c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
                pos += 1
            } else { break }
        }
        let s = String(decoding: bytes[start..<pos], as: UTF8.self)
        guard !s.isEmpty, let d = Double(s) else { throw ParseError.unexpected("valore non valido", start) }
        return .number(d)
    }
}
