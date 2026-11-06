import Foundation

// MARK: - I/O

protocol TextSink: AnyObject {
    func write(_ s: String)
}

final class BufferSink: TextSink {
    private(set) var text = ""
    func write(_ s: String) { text += s }
}

final class NullSink: TextSink {
    func write(_ s: String) {}
}

final class CallbackSink: TextSink {
    private let onWrite: (String) -> Void
    init(_ onWrite: @escaping (String) -> Void) { self.onWrite = onWrite }
    func write(_ s: String) { onWrite(s) }
}

final class FileSink: TextSink {
    private let handle: FileHandle?
    let path: String
    init(url: URL, append: Bool) {
        path = url.path
        let fm = FileManager.default
        if !append || !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        if append { _ = try? handle?.seekToEnd() }
    }
    func write(_ s: String) {
        guard let data = s.data(using: .utf8) else { return }
        try? handle?.write(contentsOf: data)
    }
    deinit { try? handle?.close() }
}

/// Stdin condiviso: più comandi (es. `read` in un while) consumano lo stesso flusso.
final class InputSource {
    private var chars: [Character]
    private var offset = 0
    init(_ text: String) { chars = Array(text) }
    static let empty = InputSource("")

    var isAtEnd: Bool { offset >= chars.count }

    func readAll() -> String {
        guard offset < chars.count else { return "" }
        let s = String(chars[offset...])
        offset = chars.count
        return s
    }

    /// Legge una riga (senza terminatore). nil a fine input. `hadNewline` indica se terminava con \n.
    func readLine(delimiter: Character = "\n") -> (String, Bool)? {
        guard offset < chars.count else { return nil }
        var s = ""
        while offset < chars.count {
            let c = chars[offset]
            offset += 1
            if c == delimiter { return (s, true) }
            s.append(c)
        }
        return (s, false)
    }
}

struct ShIO {
    var stdin: InputSource
    var stdout: TextSink
    var stderr: TextSink
}

// MARK: - Controllo di flusso

enum ShellControl: Error {
    case exit(Int32)
    case returned(Int32)
    case breakLoop(Int)
    case continueLoop(Int)
}

struct ShellRuntimeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Stato

final class ShellState {
    var vars: [String: String] = [:]
    var exported: Set<String> = []
    var functions: [String: ShNode] = [:]
    var positional: [String] = []
    var scriptName = "bash"
    var lastStatus: Int32 = 0
    var errexit = false
    var pipefail = false
    var nounset = false
    var xtrace = false
    var noglob = false
    var localFrames: [[String: String?]] = []
    var exitTrap: String?
    var startDate = Date()

    var cwd: String {
        get { vars["PWD"] ?? "/" }
        set { vars["PWD"] = newValue }
    }

    func copy() -> ShellState {
        let s = ShellState()
        s.vars = vars
        s.exported = exported
        s.functions = functions
        s.positional = positional
        s.scriptName = scriptName
        s.lastStatus = lastStatus
        s.errexit = errexit
        s.pipefail = pipefail
        s.nounset = nounset
        s.xtrace = xtrace
        s.noglob = noglob
        s.startDate = startDate
        return s
    }

    /// Stato "figlio" per un nuovo processo (bash script.sh): solo variabili esportate.
    func childProcess() -> ShellState {
        let s = ShellState()
        for name in exported { if let v = vars[name] { s.vars[name] = v } }
        s.vars["PWD"] = cwd
        s.exported = exported
        s.startDate = Date()
        return s
    }

    func setVar(_ name: String, _ value: String, export: Bool = false) {
        vars[name] = value
        if export { exported.insert(name) }
    }

    func unsetVar(_ name: String) {
        vars.removeValue(forKey: name)
        exported.remove(name)
    }

    func declareLocal(_ name: String) {
        guard !localFrames.isEmpty else { return }
        if localFrames[localFrames.count - 1][name] == nil {
            localFrames[localFrames.count - 1][name] = .some(vars[name])
        }
    }

    var environment: [String: String] {
        var env: [String: String] = [:]
        for name in exported { if let v = vars[name] { env[name] = v } }
        return env
    }
}

// MARK: - Pattern glob della shell

enum ShellPattern {
    /// Converte un pattern glob (con '\' come escape) in regex.
    static func regex(_ pattern: String, anchored: Bool = true, caseInsensitive: Bool = false) -> NSRegularExpression? {
        var re = anchored ? "^" : ""
        let chars = Array(pattern)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\":
                if i + 1 < chars.count { re += NSRegularExpression.escapedPattern(for: String(chars[i + 1])); i += 2; continue }
                re += "\\\\"
            case "*": re += ".*"
            case "?": re += "."
            case "[":
                var j = i + 1
                var cls = "["
                if j < chars.count, chars[j] == "!" || chars[j] == "^" { cls += "^"; j += 1 }
                if j < chars.count, chars[j] == "]" { cls += "\\]"; j += 1 }
                var closed = false
                while j < chars.count {
                    if chars[j] == "]" { closed = true; break }
                    if chars[j] == "[", j + 1 < chars.count, chars[j + 1] == ":" {
                        if let end = String(chars[j...]).range(of: ":]") {
                            let name = String(String(chars[j...])[..<end.upperBound])
                            cls += name
                            j += name.count
                            continue
                        }
                    }
                    if chars[j] == "\\" { cls += "\\\\"; j += 1; continue }
                    cls.append(chars[j])
                    j += 1
                }
                if closed { re += cls + "]"; i = j + 1; continue }
                re += "\\["
            default:
                re += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        if anchored { re += "$" }
        return try? NSRegularExpression(pattern: re, options: caseInsensitive ? [.caseInsensitive, .dotMatchesLineSeparators] : [.dotMatchesLineSeparators])
    }

    static func matches(_ s: String, _ pattern: String) -> Bool {
        guard let r = regex(pattern) else { return s == pattern }
        return r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func hasGlobChars(_ pattern: String) -> Bool {
        var escaped = false
        for c in pattern {
            if escaped { escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if c == "*" || c == "?" || c == "[" { return true }
        }
        return false
    }

    static func unescape(_ pattern: String) -> String {
        var out = ""
        var escaped = false
        for c in pattern {
            if escaped { out.append(c); escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            out.append(c)
        }
        return out
    }

    /// Rimozione prefisso/suffisso per ${x#p} ${x##p} ${x%p} ${x%%p}.
    static func removePrefix(_ s: String, _ pattern: String, longest: Bool) -> String {
        let chars = Array(s)
        let range: [Int] = longest ? Array((0...chars.count).reversed()) : Array(0...chars.count)
        for n in range where matches(String(chars[0..<n]), pattern) { return String(chars[n...]) }
        return s
    }

    static func removeSuffix(_ s: String, _ pattern: String, longest: Bool) -> String {
        let chars = Array(s)
        let range: [Int] = longest ? Array(0...chars.count) : Array((0...chars.count).reversed())
        for n in range where matches(String(chars[n...]), pattern) { return String(chars[0..<n]) }
        return s
    }

    static func replace(_ s: String, _ pattern: String, with rep: String, all: Bool, anchor: Character?) -> String {
        let chars = Array(s)
        if anchor == "#" {
            for n in (0...chars.count).reversed() where matches(String(chars[0..<n]), pattern) {
                return rep + String(chars[n...])
            }
            return s
        }
        if anchor == "%" {
            for n in 0...chars.count where matches(String(chars[n...]), pattern) {
                return String(chars[0..<n]) + rep
            }
            return s
        }
        var out = ""
        var i = 0
        var replaced = false
        while i < chars.count {
            if replaced && !all { out += String(chars[i...]); break }
            var matchedLen = -1
            if !pattern.isEmpty {
                for n in stride(from: chars.count, to: i, by: -1) where matches(String(chars[i..<n]), pattern) {
                    matchedLen = n - i
                    break
                }
            }
            if matchedLen > 0 {
                out += rep
                i += matchedLen
                replaced = true
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }
}
