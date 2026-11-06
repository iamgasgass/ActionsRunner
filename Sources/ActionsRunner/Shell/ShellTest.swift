import Foundation

/// Implementazione di `test`, `[ ]` e `[[ ]]`.
enum ShellTest {
    struct Parser {
        var args: [(String, Bool)]
        var pos = 0
        let extended: Bool
        let interp: ShellInterpreter

        var atEnd: Bool { pos >= args.count }
        func peek(_ o: Int = 0) -> String? { pos + o < args.count ? args[pos + o].0 : nil }

        mutating func parseOr() throws -> Bool {
            var v = try parseAnd()
            while let p = peek(), p == "-o" || (extended && p == "||") {
                pos += 1
                let r = try parseAnd()
                v = v || r
            }
            return v
        }

        mutating func parseAnd() throws -> Bool {
            var v = try parseNot()
            while let p = peek(), p == "-a" || (extended && p == "&&") {
                pos += 1
                let r = try parseNot()
                v = v && r
            }
            return v
        }

        mutating func parseNot() throws -> Bool {
            if peek() == "!" && args.count - pos > 1 {
                pos += 1
                let v = try parseNot()
                return !v
            }
            return try parsePrimary()
        }

        mutating func parsePrimary() throws -> Bool {
            guard let a = peek() else { return false }
            if a == "(", !args[pos].1 {
                pos += 1
                let v = try parseOr()
                guard peek() == ")" else { throw ShellRuntimeError(message: "test: ')' mancante") }
                pos += 1
                return v
            }
            // operatore binario
            if pos + 2 < args.count, let op = peek(1), !args[pos + 1].1,
               ShellTest.binaryOps.contains(op) || (extended && (op == "=~" || op == "<" || op == ">")) {
                let rightQuoted = args[pos + 2].1
                let right = args[pos + 2].0
                pos += 3
                return try ShellTest.binary(a, op, right, rightQuoted: rightQuoted, extended: extended, interp: interp)
            }
            if a.hasPrefix("-"), a.count == 2, let operand = peek(1) {
                if ShellTest.unaryOps.contains(a) {
                    pos += 2
                    return ShellTest.unary(a, operand, interp: interp)
                }
            }
            pos += 1
            return !a.isEmpty
        }
    }

    static let unaryOps: Set<String> = ["-z", "-n", "-e", "-f", "-d", "-s", "-r", "-w", "-x", "-L", "-h", "-a", "-v", "-p", "-S", "-b", "-c", "-t", "-g", "-u", "-k", "-O", "-G", "-N"]
    static let binaryOps: Set<String> = ["=", "==", "!=", "-eq", "-ne", "-lt", "-le", "-gt", "-ge", "-nt", "-ot", "-ef"]

    static func evaluate(_ args: [(String, Bool)], extended: Bool, interp: ShellInterpreter) throws -> Bool {
        if args.isEmpty { return false }
        var p = Parser(args: args, extended: extended, interp: interp)
        let v = try p.parseOr()
        if !p.atEnd { throw ShellRuntimeError(message: "test: troppi argomenti") }
        return v
    }

    static func unary(_ op: String, _ operand: String, interp: ShellInterpreter) -> Bool {
        let fm = FileManager.default
        let path = interp.resolve(operand).path
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: path, isDirectory: &isDir)
        switch op {
        case "-z": return operand.isEmpty
        case "-n": return !operand.isEmpty
        case "-e", "-a": return exists
        case "-f": return exists && !isDir.boolValue
        case "-d": return exists && isDir.boolValue
        case "-s":
            let size = ((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
            return exists && size > 0
        case "-r": return fm.isReadableFile(atPath: path)
        case "-w": return fm.isWritableFile(atPath: path)
        case "-x":
            if isDir.boolValue { return exists }
            let perms = ((try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? 0
            return exists && (perms & 0o111) != 0
        case "-L", "-h":
            return (try? fm.destinationOfSymbolicLink(atPath: path)) != nil
        case "-v": return interp.state.vars[operand] != nil
        case "-t": return false
        default: return false
        }
    }

    static func binary(_ l: String, _ op: String, _ r: String, rightQuoted: Bool, extended: Bool, interp: ShellInterpreter) throws -> Bool {
        switch op {
        case "=", "==":
            if extended && !rightQuoted { return ShellPattern.matches(l, r) }
            return l == r
        case "!=":
            if extended && !rightQuoted { return !ShellPattern.matches(l, r) }
            return l != r
        case "<": return l < r
        case ">": return l > r
        case "=~":
            guard let re = try? NSRegularExpression(pattern: r) else { throw ShellRuntimeError(message: "regex non valida: \(r)") }
            let range = NSRange(l.startIndex..., in: l)
            guard let m = re.firstMatch(in: l, range: range) else { return false }
            // BASH_REMATCH come variabili BASH_REMATCH_0..n (array non supportati)
            for g in 0..<m.numberOfRanges {
                if let rr = Range(m.range(at: g), in: l) { interp.state.setVar("BASH_REMATCH_\(g)", String(l[rr])) }
            }
            if let rr = Range(m.range(at: 0), in: l) { interp.state.setVar("BASH_REMATCH", String(l[rr])) }
            return true
        case "-eq", "-ne", "-lt", "-le", "-gt", "-ge":
            let a = try intValue(l, interp), b = try intValue(r, interp)
            switch op {
            case "-eq": return a == b
            case "-ne": return a != b
            case "-lt": return a < b
            case "-le": return a <= b
            case "-gt": return a > b
            default: return a >= b
            }
        case "-nt", "-ot":
            let fm = FileManager.default
            let d1 = (try? fm.attributesOfItem(atPath: interp.resolve(l).path)[.modificationDate]) as? Date
            let d2 = (try? fm.attributesOfItem(atPath: interp.resolve(r).path)[.modificationDate]) as? Date
            guard let a = d1 else { return false }
            guard let b = d2 else { return op == "-nt" }
            return op == "-nt" ? a > b : a < b
        case "-ef":
            return interp.resolve(l).resolvingSymlinksInPath().path == interp.resolve(r).resolvingSymlinksInPath().path
        default:
            return false
        }
    }

    private static func intValue(_ s: String, _ interp: ShellInterpreter) throws -> Int64 {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let v = Int64(t) { return v }
        if t.isEmpty { return 0 }
        throw ShellRuntimeError(message: "\(s): attesa espressione intera")
    }
}
