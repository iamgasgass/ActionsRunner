import Foundation
import Yams

/// Carica YAML usando lo schema "core" di YAML 1.2, come il parser di GitHub Actions:
/// `on`, `yes`, `no`, `off` restano stringhe (in YAML 1.1 sarebbero booleani).
enum YAMLLoader {
    struct LoadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func load(_ text: String) throws -> JSONValue {
        do {
            guard let node = try Yams.compose(yaml: text) else { return .null }
            return convert(node)
        } catch {
            throw LoadError(message: "YAML non valido: \(error)")
        }
    }

    static func convert(_ node: Node) -> JSONValue {
        switch node {
        case .scalar(let scalar):
            return resolve(scalar)
        case .mapping(let mapping):
            var object = OrderedObject()
            for pair in mapping {
                let key = keyString(pair.key)
                if key == "<<" {
                    // Merge key YAML: unisce le chiavi dell'ancora senza sovrascrivere quelle esplicite
                    let merged = convert(pair.value)
                    let sources: [JSONValue] = merged.arrayValue ?? [merged]
                    for source in sources {
                        if let o = source.objectValue {
                            for (k, v) in o.pairs where object[k] == nil { object[k] = v }
                        }
                    }
                    continue
                }
                object[key] = convert(pair.value)
            }
            return .object(object)
        case .sequence(let sequence):
            return .array(sequence.map { convert($0) })
        default:
            return .null
        }
    }

    private static func keyString(_ node: Node) -> String {
        if case .scalar(let s) = node { return s.string }
        return convert(node).toJSON(pretty: false)
    }

    private static let intPattern = try! NSRegularExpression(pattern: "^[-+]?[0-9]+$")
    private static let floatPattern = try! NSRegularExpression(pattern: "^[-+]?(\\.[0-9]+|[0-9]+(\\.[0-9]*)?)([eE][-+]?[0-9]+)?$")

    static func resolve(_ scalar: Node.Scalar) -> JSONValue {
        let s = scalar.string
        switch scalar.style {
        case .plain, .any:
            break
        default:
            return .string(s)
        }
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
}
