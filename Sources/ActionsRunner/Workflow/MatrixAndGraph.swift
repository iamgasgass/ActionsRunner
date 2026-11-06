import Foundation

enum MatrixExpander {
    static let maxJobs = 256

    /// Espande `strategy.matrix` seguendo esattamente le regole documentate da GitHub:
    /// 1. prodotto cartesiano dei vettori (prima chiave = ciclo più esterno)
    /// 2. rimozione delle combinazioni corrispondenti (anche parzialmente) a `exclude`
    /// 3. per ogni oggetto di `include`: viene aggiunto a tutte le combinazioni originali in cui
    ///    non sovrascrive valori originali; se non è aggiungibile a nessuna, diventa una nuova combinazione.
    static func expand(_ matrix: JSONValue) throws -> [OrderedObject] {
        guard let m = matrix.objectValue else {
            throw ExpressionError(message: "strategy.matrix deve essere una mappa (trovato \(matrix.typeName))")
        }
        var vectorKeys: [String] = []
        var vectors: [[JSONValue]] = []
        for (k, v) in m.pairs where k != "include" && k != "exclude" {
            guard let arr = v.arrayValue else {
                throw ExpressionError(message: "La variabile di matrix '\(k)' deve essere un array")
            }
            if arr.isEmpty { throw ExpressionError(message: "La variabile di matrix '\(k)' è un array vuoto") }
            vectorKeys.append(k)
            vectors.append(arr)
        }

        var combos: [OrderedObject] = []
        if !vectorKeys.isEmpty {
            combos = [OrderedObject()]
            for (i, key) in vectorKeys.enumerated() {
                var next: [OrderedObject] = []
                for combo in combos {
                    for value in vectors[i] {
                        var c = combo
                        c[key] = value
                        next.append(c)
                    }
                }
                combos = next
            }
        }

        if let excludes = m["exclude"]?.arrayValue {
            for ex in excludes {
                guard let exObj = ex.objectValue else { continue }
                combos.removeAll { combo in
                    exObj.pairs.allSatisfy { pair in
                        guard let v = combo[pair.key] else { return false }
                        return partialMatch(v, pair.value)
                    }
                }
            }
        }

        let originalCount = combos.count
        let originalKeys = Set(vectorKeys)
        // Valori originali per combinazione (non sovrascrivibili)
        let originalValues = combos

        if let includes = m["include"]?.arrayValue {
            for inc in includes {
                guard let incObj = inc.objectValue else {
                    throw ExpressionError(message: "Ogni elemento di matrix.include deve essere una mappa")
                }
                var added = false
                for idx in 0..<originalCount {
                    let original = originalValues[idx]
                    let compatible = incObj.pairs.allSatisfy { pair in
                        guard originalKeys.contains(pair.key), let ov = original[pair.key] else { return true }
                        return ov == pair.value
                    }
                    if compatible {
                        for (k, v) in incObj.pairs where !(originalKeys.contains(k) && original[k] != nil) {
                            combos[idx][k] = v
                        }
                        added = true
                    }
                }
                if !added { combos.append(incObj) }
            }
        }

        if combos.isEmpty {
            throw ExpressionError(message: "La matrix non produce alcuna combinazione")
        }
        if combos.count > maxJobs {
            throw ExpressionError(message: "La matrix genera \(combos.count) job: il limite di GitHub è \(maxJobs)")
        }
        return combos
    }

    /// Un valore di exclude può essere un sotto-oggetto del valore della matrix.
    private static func partialMatch(_ value: JSONValue, _ pattern: JSONValue) -> Bool {
        if case .object(let po) = pattern, case .object(let vo) = value {
            return po.pairs.allSatisfy { p in vo[p.key].map { partialMatch($0, p.value) } ?? false }
        }
        return value == pattern
    }

    /// Nome visualizzato come su GitHub: "build (ubuntu-latest, 18)".
    static func displayName(base: String, combo: OrderedObject, total: Int, nameIsCustom: Bool) -> String {
        guard total > 1 || !combo.isEmpty, !nameIsCustom else { return base }
        let values = combo.values.map { v -> String in
            switch v {
            case .object, .array: return v.toJSON(pretty: false)
            default: return v.stringValue
            }
        }
        return values.isEmpty ? base : "\(base) (\(values.joined(separator: ", ")))"
    }
}

enum JobGraph {
    /// Ordinamento topologico stabile (rispetta l'ordine del file a parità di livello).
    static func topologicalOrder(_ jobs: [Job]) throws -> [Job] {
        let byId = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
        var visited = Set<String>()
        var visiting = Set<String>()
        var order: [Job] = []

        func visit(_ id: String, _ path: [String]) throws {
            if visited.contains(id) { return }
            if visiting.contains(id) {
                throw ExpressionError(message: "Ciclo nei 'needs': \((path + [id]).joined(separator: " → "))")
            }
            guard let job = byId[id] else { return }
            visiting.insert(id)
            for n in job.needs { try visit(n, path + [id]) }
            visiting.remove(id)
            visited.insert(id)
            order.append(job)
        }
        for j in jobs { try visit(j.id, []) }
        return order
    }

    static func findCycle(_ jobs: [Job]) -> [String]? {
        do { _ = try topologicalOrder(jobs); return nil } catch {
            let msg = error.localizedDescription
            if let r = msg.range(of: ": ") { return msg[r.upperBound...].components(separatedBy: " → ") }
            return [msg]
        }
    }

    /// Antenati transitivi (per success()/failure() a livello di job).
    static func ancestors(of id: String, in jobs: [Job]) -> Set<String> {
        let byId = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
        var result = Set<String>()
        var stack = byId[id]?.needs ?? []
        while let n = stack.popLast() {
            if result.insert(n).inserted { stack.append(contentsOf: byId[n]?.needs ?? []) }
        }
        return result
    }

    /// Livelli (per il diagramma): ogni job è al livello max(livello needs)+1.
    static func levels(_ jobs: [Job]) -> [[Job]] {
        guard let ordered = try? topologicalOrder(jobs) else { return [jobs] }
        var level: [String: Int] = [:]
        for j in ordered { level[j.id] = (j.needs.compactMap { level[$0] }.max() ?? -1) + 1 }
        let maxLevel = level.values.max() ?? 0
        return (0...maxLevel).map { l in jobs.filter { level[$0.id] == l } }
    }
}

/// Pattern di filtro di GitHub per branches/tags/paths:
/// `*` = qualsiasi carattere tranne '/', `**` = qualsiasi carattere, `?` = zero o uno del precedente,
/// `+` = uno o più del precedente, `[]` classi, `!` iniziale = negazione.
enum FilterPattern {
    static func regex(for pattern: String) -> NSRegularExpression? {
        var re = "^"
        let chars = Array(pattern)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    re += ".*"; i += 2
                    if i < chars.count, chars[i] == "/" { re += "(?:/)?" ; i += 1 }
                    continue
                }
                re += "[^/]*"
            case "?": re += "?"
            case "+": re += "+"
            case "[":
                if let close = chars[(i + 1)...].firstIndex(of: "]") {
                    re += "[" + String(chars[(i + 1)..<close]) + "]"
                    i = close + 1
                    continue
                }
                re += "\\["
            case "\\":
                if i + 1 < chars.count { re += NSRegularExpression.escapedPattern(for: String(chars[i + 1])); i += 2; continue }
                re += "\\\\"
            default:
                re += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        re += "$"
        return try? NSRegularExpression(pattern: re)
    }

    static func matches(_ value: String, pattern: String) -> Bool {
        guard let r = regex(for: pattern) else { return false }
        return r.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    /// Applica una lista di pattern con negazioni in ordine (l'ultimo che corrisponde vince).
    static func evaluate(_ value: String, patterns: [String]) -> Bool {
        var result = false
        for p in patterns {
            if p.hasPrefix("!") {
                if matches(value, pattern: String(p.dropFirst())) { result = false }
            } else if matches(value, pattern: p) {
                result = true
            }
        }
        return result
    }

    /// Controlla se un evento push/pull_request su `branch` attiverebbe il workflow.
    static func triggerMatches(config: JSONValue?, branch: String, isTag: Bool) -> Bool {
        guard let cfg = config?.objectValue else { return true }
        func list(_ key: String) -> [String]? {
            guard let v = cfg[key] else { return nil }
            if let a = v.arrayValue { return a.map { $0.stringValue } }
            return [v.stringValue]
        }
        if isTag {
            if let tags = list("tags") { return evaluate(branch, patterns: tags) }
            if let ignore = list("tags-ignore") { return !evaluate(branch, patterns: ignore) }
            return list("branches") == nil && list("branches-ignore") == nil
        }
        if let branches = list("branches") { return evaluate(branch, patterns: branches) }
        if let ignore = list("branches-ignore") { return !evaluate(branch, patterns: ignore) }
        if list("tags") != nil || list("tags-ignore") != nil { return false }
        return true
    }
}
