import Foundation

/// Stato condiviso a livello di job per i comandi `::...::` e le maschere dei segreti.
final class CommandState {
    var masks: [String] = []
    var stopToken: String?
    var echoCommands = false
    var debug = false

    func addMask(_ value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty, !masks.contains(v) else { return }
        masks.append(v)
        // Maschera anche le singole righe dei valori multilinea
        for line in v.components(separatedBy: "\n") where line.count >= 2 && !masks.contains(line) { masks.append(line) }
        masks.sort { $0.count > $1.count }
    }

    func mask(_ s: String) -> String {
        guard !masks.isEmpty else { return s }
        var out = s
        for m in masks where out.contains(m) { out = out.replacingOccurrences(of: m, with: "***") }
        return out
    }
}

enum WorkflowCommandResult {
    case log(LogLine.Kind, String)
    case annotation(RunAnnotation, String)
    case setOutput(String, String)
    case saveState(String, String)
    case none
}

enum WorkflowCommands {
    static func unescapeData(_ s: String) -> String {
        s.replacingOccurrences(of: "%0D", with: "\r")
            .replacingOccurrences(of: "%0A", with: "\n")
            .replacingOccurrences(of: "%25", with: "%")
    }

    static func unescapeProperty(_ s: String) -> String {
        unescapeData(s).replacingOccurrences(of: "%3A", with: ":").replacingOccurrences(of: "%2C", with: ",")
    }

    /// Interpreta una riga di output di uno step.
    static func process(_ raw: String, _ state: CommandState) -> WorkflowCommandResult {
        var line = raw
        if line.hasSuffix("\r") { line.removeLast() }

        if let token = state.stopToken {
            if line == "::\(token)::" { state.stopToken = nil; return .none }
            return .log(.output, line)
        }

        // Formato legacy ##[group] ecc.
        if line.hasPrefix("##[") , let close = line.firstIndex(of: "]") {
            let cmd = String(line[line.index(line.startIndex, offsetBy: 3)..<close]).lowercased()
            let msg = String(line[line.index(after: close)...])
            switch cmd {
            case "group": return .log(.groupStart, msg)
            case "endgroup": return .log(.groupEnd, "")
            case "error": return .annotation(RunAnnotation(level: "error", message: msg), "Error: \(msg)")
            case "warning": return .annotation(RunAnnotation(level: "warning", message: msg), "Warning: \(msg)")
            case "notice": return .annotation(RunAnnotation(level: "notice", message: msg), "Notice: \(msg)")
            case "debug": return state.debug ? .log(.debug, "##[debug]\(msg)") : .none
            default: break
            }
        }

        guard line.hasPrefix("::") else { return .log(.output, line) }
        let body = line.dropFirst(2)
        guard let sep = body.range(of: "::") else { return .log(.output, line) }
        let head = String(body[..<sep.lowerBound])
        let value = String(body[sep.upperBound...])
        var name = head
        var props: [String: String] = [:]
        if let space = head.firstIndex(of: " ") {
            name = String(head[..<space])
            for pair in head[head.index(after: space)...].split(separator: ",") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { props[kv[0].trimmingCharacters(in: .whitespaces)] = unescapeProperty(kv[1]) }
            }
        }
        let data = unescapeData(value)
        let echo: [WorkflowCommandResult] = state.echoCommands ? [.log(.command, line)] : []
        _ = echo

        switch name {
        case "group": return .log(.groupStart, data)
        case "endgroup": return .log(.groupEnd, "")
        case "debug": return state.debug ? .log(.debug, "##[debug]\(data)") : .none
        case "error", "warning", "notice":
            var a = RunAnnotation(level: name, message: data)
            a.title = props["title"]
            a.file = props["file"]
            a.line = props["line"].flatMap { Int($0) }
            let loc = [a.file, a.line.map { "riga \($0)" }].compactMap { $0 }.joined(separator: ", ")
            let prefix = name == "error" ? "Error" : (name == "warning" ? "Warning" : "Notice")
            return .annotation(a, "\(prefix)\(loc.isEmpty ? "" : " (\(loc))"): \(a.title.map { "\($0): " } ?? "")\(data)")
        case "add-mask":
            state.addMask(data)
            return .none
        case "set-output":
            guard let n = props["name"] else { return .log(.output, line) }
            return .setOutput(n, data)
        case "save-state":
            guard let n = props["name"] else { return .log(.output, line) }
            return .saveState(n, data)
        case "stop-commands":
            state.stopToken = data
            return .none
        case "echo":
            state.echoCommands = data.lowercased() == "on"
            return .none
        case "set-env", "add-path":
            return .log(.error, "Il comando `\(name)` è disabilitato. Usa i file di ambiente ($GITHUB_ENV / $GITHUB_PATH).")
        case "add-matcher", "remove-matcher":
            return .log(.info, "Problem matcher \(name == "add-matcher" ? "aggiunto" : "rimosso"): \(data)")
        default:
            return .log(.output, line)
        }
    }
}

/// Parsing dei file $GITHUB_OUTPUT / $GITHUB_ENV / $GITHUB_STATE (name=value o name<<DELIM).
enum EnvironmentFile {
    struct ParseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func parse(_ text: String) throws -> [(String, String)] {
        var result: [(String, String)] = []
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var i = 0
        while i < lines.count {
            var line = lines[i]
            if line.hasSuffix("\r") { line.removeLast() }
            if line.isEmpty { i += 1; continue }
            let heredoc = line.range(of: "<<")
            let eq = line.firstIndex(of: "=")
            if let h = heredoc, eq == nil || h.lowerBound < eq! {
                let name = String(line[..<h.lowerBound])
                let delim = String(line[h.upperBound...])
                guard !name.isEmpty else { throw ParseError(message: "Nome mancante nella riga '\(line)'") }
                guard !delim.isEmpty else { throw ParseError(message: "Delimitatore mancante per '\(name)'") }
                var valueLines: [String] = []
                i += 1
                var closed = false
                while i < lines.count {
                    var l = lines[i]
                    if l.hasSuffix("\r") { l.removeLast() }
                    if l == delim { closed = true; break }
                    valueLines.append(l)
                    i += 1
                }
                guard closed else { throw ParseError(message: "Delimitatore '\(delim)' non trovato per '\(name)'") }
                result.append((name, valueLines.joined(separator: "\n")))
                i += 1
            } else if let e = eq {
                let name = String(line[..<e])
                guard !name.isEmpty else { throw ParseError(message: "Nome mancante nella riga '\(line)'") }
                result.append((name, String(line[line.index(after: e)...])))
                i += 1
            } else {
                throw ParseError(message: "Formato non valido: '\(line)'")
            }
        }
        return result
    }
}
