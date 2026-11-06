import Foundation

// MARK: - date

enum DateCommand {
    static func run(_ args: [String], _ io: ShIO) -> Int32 {
        var utc = false
        var format: String? = nil
        var date = Date()
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "-u" || a == "--utc" { utc = true }
            else if a.hasPrefix("+") { format = String(a.dropFirst()) }
            else if a == "-d" || a == "--date", i + 1 < args.count {
                let v = args[i + 1]
                if v.hasPrefix("@"), let t = Double(v.dropFirst()) { date = Date(timeIntervalSince1970: t) }
                else if let d = ISO8601DateFormatter().date(from: v) { date = d }
                i += 1
            } else if a.hasPrefix("-I") || a == "--iso-8601" {
                format = a.contains("seconds") ? "%Y-%m-%dT%H:%M:%S%z" : "%Y-%m-%d"
            } else if a == "-R" { format = "%a, %d %b %Y %H:%M:%S %z" }
            i += 1
        }
        let tz = utc ? TimeZone(identifier: "UTC")! : TimeZone.current
        let fmt = format ?? "%a %b %e %H:%M:%S %Z %Y"
        io.stdout.write(strftime(fmt, date, tz) + "\n")
        return 0
    }

    static func strftime(_ fmt: String, _ date: Date, _ tz: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday, .nanosecond], from: date)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = tz
        func f(_ p: String) -> String { df.dateFormat = p; return df.string(from: date) }
        var out = ""
        let c = Array(fmt)
        var i = 0
        while i < c.count {
            guard c[i] == "%", i + 1 < c.count else { out.append(c[i]); i += 1; continue }
            var spec = c[i + 1]
            var noPad = false
            if spec == "-", i + 2 < c.count { noPad = true; spec = c[i + 2]; i += 1 }
            func pad(_ v: Int, _ w: Int = 2) -> String { noPad ? String(v) : String(format: "%0\(w)d", v) }
            switch spec {
            case "Y": out += String(comps.year ?? 0)
            case "y": out += pad((comps.year ?? 0) % 100)
            case "m": out += pad(comps.month ?? 0)
            case "d": out += pad(comps.day ?? 0)
            case "e": out += String(format: "%2d", comps.day ?? 0)
            case "H": out += pad(comps.hour ?? 0)
            case "I": out += pad(((comps.hour ?? 0) + 11) % 12 + 1)
            case "M": out += pad(comps.minute ?? 0)
            case "S": out += pad(comps.second ?? 0)
            case "N": out += String(format: "%09d", comps.nanosecond ?? 0)
            case "s": out += String(Int(date.timeIntervalSince1970))
            case "j": out += pad(cal.ordinality(of: .day, in: .year, for: date) ?? 0, 3)
            case "u": out += String(((comps.weekday ?? 1) + 5) % 7 + 1)
            case "w": out += String((comps.weekday ?? 1) - 1)
            case "a": out += f("EEE")
            case "A": out += f("EEEE")
            case "b", "h": out += f("MMM")
            case "B": out += f("MMMM")
            case "p": out += f("a")
            case "Z": out += tz.abbreviation(for: date) ?? "UTC"
            case "z": out += f("xx")
            case "F": out += strftime("%Y-%m-%d", date, tz)
            case "T": out += strftime("%H:%M:%S", date, tz)
            case "D": out += strftime("%m/%d/%y", date, tz)
            case "R": out += strftime("%H:%M", date, tz)
            case "c": out += strftime("%a %b %e %H:%M:%S %Y", date, tz)
            case "n": out += "\n"
            case "t": out += "\t"
            case "%": out += "%"
            default: out.append("%"); out.append(spec)
            }
            i += 2
        }
        return out
    }
}

// MARK: - curl / wget

enum NetCommands {
    static func fetch(_ name: String, _ args: [String], _ io: ShIO, _ sh: ShellInterpreter) async -> Int32 {
        var url: String? = nil
        var output: String? = nil
        var remoteName = false
        var method: String? = nil
        var headers: [(String, String)] = []
        var body: Data? = nil
        var failOnError = false
        var silent = name == "wget" ? false : false
        var headOnly = false
        var includeHeaders = false
        var writeOut: String? = nil
        var user: String? = nil
        var i = 0
        while i < args.count {
            let a = args[i]
            func nextArg() -> String? { i += 1; return i < args.count ? args[i] : nil }
            switch a {
            case "-o", "--output", "-O" where name == "wget", "--output-document": output = nextArg()
            case "-O", "--remote-name": remoteName = true
            case "-X", "--request": method = nextArg()
            case "-H", "--header":
                if let h = nextArg(), let colon = h.firstIndex(of: ":") {
                    headers.append((String(h[..<colon]).trimmingCharacters(in: .whitespaces), String(h[h.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
                }
            case "-d", "--data", "--data-raw", "--data-binary", "--data-urlencode":
                if let d = nextArg() {
                    if d.hasPrefix("@"), let fileData = try? Data(contentsOf: sh.resolve(String(d.dropFirst()))) { body = fileData }
                    else { body = Data(d.utf8) }
                    if method == nil { method = "POST" }
                }
            case "--json":
                if let d = nextArg() { body = Data(d.utf8); method = method ?? "POST"; headers.append(("Content-Type", "application/json")); headers.append(("Accept", "application/json")) }
            case "-T", "--upload-file":
                if let f = nextArg() { body = try? Data(contentsOf: sh.resolve(f)); method = method ?? "PUT" }
            case "-u", "--user": user = nextArg()
            case "-f", "--fail", "--fail-with-body": failOnError = true
            case "-s", "--silent", "-q", "--quiet": silent = true
            case "-I", "--head": headOnly = true; method = "HEAD"
            case "-i", "--include": includeHeaders = true
            case "-w", "--write-out": writeOut = nextArg()
            case "-A", "--user-agent": if let ua = nextArg() { headers.append(("User-Agent", ua)) }
            case "-e", "--referer": if let r = nextArg() { headers.append(("Referer", r)) }
            case "--retry", "--retry-delay", "--max-time", "-m", "--connect-timeout", "-r", "--range", "-b", "-c", "--cacert", "--max-redirs":
                _ = nextArg()
            default:
                if a.hasPrefix("-") {
                    // flag combinati come -fsSL
                    if !a.hasPrefix("--") {
                        for f in a.dropFirst() {
                            if f == "f" { failOnError = true }
                            if f == "s" { silent = true }
                            if f == "I" { headOnly = true; method = "HEAD" }
                            if f == "i" { includeHeaders = true }
                            if f == "O" { remoteName = true }
                            if f == "q" { silent = true }
                        }
                    }
                } else {
                    url = a
                }
            }
            i += 1
        }
        _ = silent
        guard let urlString = url, let u = URL(string: urlString.hasPrefix("http") ? urlString : "https://" + urlString) else {
            io.stderr.write("\(name): URL mancante o non valido\n")
            return name == "curl" ? 3 : 1
        }
        var req = URLRequest(url: u)
        req.httpMethod = method ?? "GET"
        req.httpBody = body
        req.setValue("curl/8.10.1 (ActionsRunner-iOS)", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let user = user {
            req.setValue("Basic " + Data(user.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            var headerText = ""
            if includeHeaders || headOnly, let h = http {
                headerText = "HTTP/2 \(status)\r\n" + h.allHeaderFields.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") + "\r\n\r\n"
            }
            if failOnError && status >= 400 {
                io.stderr.write("\(name): (22) The requested URL returned error: \(status)\n")
                return name == "curl" ? 22 : 8
            }
            var target = output
            if target == nil && (remoteName && name == "curl") { target = u.lastPathComponent.isEmpty ? "index.html" : u.lastPathComponent }
            if target == nil && name == "wget" { target = u.lastPathComponent.isEmpty ? "index.html" : u.lastPathComponent }
            if let t = target, t != "-" {
                let dest = sh.resolve(t)
                try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: dest)
                if !headerText.isEmpty { io.stdout.write(headerText) }
            } else {
                io.stdout.write(headerText + (headOnly ? "" : String(decoding: data, as: UTF8.self)))
            }
            if let w = writeOut {
                io.stdout.write(w.replacingOccurrences(of: "%{http_code}", with: "\(status)")
                    .replacingOccurrences(of: "%{size_download}", with: "\(data.count)")
                    .replacingOccurrences(of: "%{url_effective}", with: http?.url?.absoluteString ?? urlString)
                    .replacingOccurrences(of: "\\n", with: "\n"))
            }
            return 0
        } catch {
            io.stderr.write("\(name): (6) \(error.localizedDescription)\n")
            return name == "curl" ? 6 : 4
        }
    }
}

// MARK: - jq (sottoinsieme)

enum JQ {
    static func run(_ args: [String], _ io: ShIO, _ sh: ShellInterpreter) -> Int32 {
        var raw = false
        var compact = false
        var exitStatus = false
        var nullInput = false
        var filter: String? = nil
        var files: [String] = []
        var argVars: [String: JSONValue] = [:]
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--arg", i + 2 < args.count { argVars[args[i + 1]] = .string(args[i + 2]); i += 3; continue }
            if a == "--argjson", i + 2 < args.count { argVars[args[i + 1]] = (try? JSONValue.parse(json: args[i + 2])) ?? .null; i += 3; continue }
            if a.hasPrefix("-") && a.count > 1 && filter == nil || (a.hasPrefix("-") && a.count > 1 && filter != nil && files.isEmpty && a.hasPrefix("--")) {
                if a.hasPrefix("--") {
                    if a == "--raw-output" { raw = true }
                    if a == "--compact-output" { compact = true }
                    if a == "--exit-status" { exitStatus = true }
                    if a == "--null-input" { nullInput = true }
                } else {
                    for f in a.dropFirst() {
                        if f == "r" { raw = true }
                        if f == "c" { compact = true }
                        if f == "e" { exitStatus = true }
                        if f == "n" { nullInput = true }
                    }
                }
                i += 1; continue
            }
            if filter == nil { filter = a } else { files.append(a) }
            i += 1
        }
        let f = filter ?? "."
        guard let text = ShellBuiltins.readInputs(files, io, sh, { io.stderr.write("jq: \($0)\n") }) else { return 2 }
        var inputs: [JSONValue] = []
        if nullInput { inputs = [.null] } else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return 0 }
            if let v = try? JSONValue.parse(json: trimmed) { inputs = [v] }
            else {
                for line in ShellBuiltins.lines(trimmed) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    guard let v = try? JSONValue.parse(json: line) else { io.stderr.write("jq: error: input JSON non valido\n"); return 2 }
                    inputs.append(v)
                }
            }
        }
        var last: JSONValue = .null
        do {
            for input in inputs {
                for result in try apply(f, to: [input], vars: argVars) {
                    last = result
                    if raw, case .string(let s) = result { io.stdout.write(s + "\n") }
                    else { io.stdout.write(result.toJSON(pretty: !compact) + "\n") }
                }
            }
        } catch {
            io.stderr.write("jq: error: \(error.localizedDescription) (l'interprete iOS supporta: ., .a.b, .[n], .[], |, keys, length, select(), map(), //, type, tostring, tonumber)\n")
            return 3
        }
        if exitStatus { return last.isTruthy ? 0 : 1 }
        return 0
    }

    static func splitTop(_ s: String, by sep: String) -> [String] {
        var parts: [String] = []
        var cur = ""
        var depth = 0
        var inStr = false
        let c = Array(s)
        let sc = Array(sep)
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "\"" && (i == 0 || c[i - 1] != "\\") { inStr.toggle() }
            if !inStr {
                if "([{".contains(ch) { depth += 1 }
                if ")]}".contains(ch) { depth -= 1 }
                if depth == 0, i + sc.count <= c.count, Array(c[i..<(i + sc.count)]) == sc {
                    parts.append(cur); cur = ""; i += sc.count; continue
                }
            }
            cur.append(ch)
            i += 1
        }
        parts.append(cur)
        return parts
    }

    static func apply(_ filter: String, to inputs: [JSONValue], vars: [String: JSONValue]) throws -> [JSONValue] {
        let pipeline = splitTop(filter, by: "|")
        var current = inputs
        for stage in pipeline {
            let s = stage.trimmingCharacters(in: .whitespaces)
            var next: [JSONValue] = []
            for v in current { next.append(contentsOf: try applySingle(s, v, vars: vars)) }
            current = next
        }
        return current
    }

    static func applySingle(_ s: String, _ v: JSONValue, vars: [String: JSONValue]) throws -> [JSONValue] {
        if s.isEmpty || s == "." { return [v] }
        let commaParts = splitTop(s, by: ",")
        if commaParts.count > 1 { return try commaParts.flatMap { try applySingle($0.trimmingCharacters(in: .whitespaces), v, vars: vars) } }
        let alt = splitTop(s, by: "//")
        if alt.count > 1 {
            let left = (try? apply(alt[0], to: [v], vars: vars))?.filter { $0.isTruthy } ?? []
            if left.isEmpty { return try apply(alt.dropFirst().joined(separator: "//"), to: [v], vars: vars) }
            return left
        }
        for op in ["==", "!="] {
            let parts = splitTop(s, by: op)
            if parts.count == 2 {
                let l = try apply(parts[0], to: [v], vars: vars).first ?? .null
                let r = try apply(parts[1], to: [v], vars: vars).first ?? .null
                return [.bool((l == r) == (op == "=="))]
            }
        }
        if s.hasPrefix("\"") && s.hasSuffix("\"") { return [(try? JSONValue.parse(json: s)) ?? .string(s)] }
        if let d = Double(s) { return [.number(d)] }
        if s == "true" { return [.bool(true)] }
        if s == "false" { return [.bool(false)] }
        if s == "null" { return [.null] }
        if s.hasPrefix("$"), let val = vars[String(s.dropFirst())] { return [val] }
        switch s {
        case "keys", "keys_unsorted":
            if let o = v.objectValue { return [.array((s == "keys" ? o.keys.sorted() : o.keys).map { .string($0) })] }
            if let a = v.arrayValue { return [.array(a.indices.map { .number(Double($0)) })] }
            throw ShellRuntimeError(message: "keys su \(v.typeName)")
        case "length":
            switch v {
            case .array(let a): return [.number(Double(a.count))]
            case .object(let o): return [.number(Double(o.count))]
            case .string(let str): return [.number(Double(str.count))]
            case .null: return [.number(0)]
            default: return [.number(abs(v.numberValue))]
            }
        case "type": return [.string(v.typeName)]
        case "tostring": if case .string = v { return [v] }; return [.string(v.toJSON(pretty: false))]
        case "tonumber": return [.number(v.numberValue)]
        case "not": return [.bool(!v.isTruthy)]
        case "empty": return []
        case "add":
            guard let a = v.arrayValue, let first = a.first else { return [.null] }
            if case .string = first { return [.string(a.map { $0.stringValue }.joined())] }
            if case .array = first { return [.array(a.flatMap { $0.arrayValue ?? [] })] }
            return [.number(a.map { $0.numberValue }.reduce(0, +))]
        case "first": return [v.arrayValue?.first ?? .null]
        case "last": return [v.arrayValue?.last ?? .null]
        case "reverse": return [.array(Array((v.arrayValue ?? []).reversed()))]
        case "sort": return [.array((v.arrayValue ?? []).sorted { $0.stringValue < $1.stringValue })]
        case "to_entries":
            guard let o = v.objectValue else { return [.null] }
            return [.array(o.pairs.map { .object(OrderedObject([("key", .string($0.key)), ("value", $0.value)])) })]
        default: break
        }
        if s.hasPrefix("select(") && s.hasSuffix(")") {
            let inner = String(s.dropFirst(7).dropLast())
            let r = try apply(inner, to: [v], vars: vars).first ?? .null
            return r.isTruthy ? [v] : []
        }
        if s.hasPrefix("map(") && s.hasSuffix(")") {
            let inner = String(s.dropFirst(4).dropLast())
            return [.array(try (v.arrayValue ?? []).flatMap { try apply(inner, to: [$0], vars: vars) })]
        }
        if s.hasPrefix("has(") && s.hasSuffix(")") {
            let key = String(s.dropFirst(4).dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            return [.bool(v[key] != nil)]
        }
        if s.hasPrefix("[") && s.hasSuffix("]") {
            return [.array(try apply(String(s.dropFirst().dropLast()), to: [v], vars: vars))]
        }
        guard s.hasPrefix(".") else { throw ShellRuntimeError(message: "filtro non supportato '\(s)'") }
        // percorso: .a.b[0]["x"][]
        var results: [JSONValue] = [v]
        let c = Array(s)
        var i = 0
        while i < c.count {
            if c[i] == "." {
                i += 1
                var name = ""
                if i < c.count, c[i] == "\"" {
                    i += 1
                    while i < c.count, c[i] != "\"" { name.append(c[i]); i += 1 }
                    i += 1
                } else {
                    while i < c.count, c[i] != "." && c[i] != "[" && c[i] != "?" { name.append(c[i]); i += 1 }
                }
                if !name.isEmpty { results = results.map { $0[name] ?? .null } }
            } else if c[i] == "[" {
                var j = i + 1
                var inner = ""
                while j < c.count, c[j] != "]" { inner.append(c[j]); j += 1 }
                i = j + 1
                if inner.isEmpty {
                    results = results.flatMap { r -> [JSONValue] in
                        if let a = r.arrayValue { return a }
                        if let o = r.objectValue { return o.values }
                        return []
                    }
                } else if let n = Int(inner) {
                    results = results.map { r -> JSONValue in
                        guard let a = r.arrayValue else { return .null }
                        let idx = n < 0 ? a.count + n : n
                        return idx >= 0 && idx < a.count ? a[idx] : .null
                    }
                } else {
                    let key = inner.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    results = results.map { $0[key] ?? .null }
                }
            } else if c[i] == "?" {
                i += 1
            } else {
                throw ShellRuntimeError(message: "filtro non supportato '\(s)'")
            }
        }
        return results
    }
}

// MARK: - git (emulazione minima)

enum GitEmulation {
    static func run(_ args: [String], _ io: ShIO, _ sh: ShellInterpreter) -> Int32 {
        let sha = sh.host.gitSHA
        let ref = sh.host.gitRef
        let branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : ref
        var a = args
        while let f = a.first, f == "-C" || f == "-c" { a.removeFirst(); if !a.isEmpty { a.removeFirst() } }
        guard let sub = a.first else { io.stdout.write("usage: git <command>\n"); return 1 }
        switch sub {
        case "--version", "version":
            io.stdout.write("git version 2.51.0 (emulazione dell'interprete integrato)\n"); return 0
        case "rev-parse":
            if a.contains("--abbrev-ref") { io.stdout.write(branch + "\n"); return 0 }
            if a.contains("--show-toplevel") { io.stdout.write((sh.state.vars["GITHUB_WORKSPACE"] ?? sh.state.cwd) + "\n"); return 0 }
            if a.contains("--is-inside-work-tree") { io.stdout.write("true\n"); return 0 }
            if a.contains("--git-dir") { io.stdout.write(".git\n"); return 0 }
            if let i = a.firstIndex(where: { $0.hasPrefix("--short") }) {
                let n = a[i].contains("=") ? Int(a[i].split(separator: "=").last ?? "7") ?? 7 : 7
                io.stdout.write(String(sha.prefix(n)) + "\n"); return 0
            }
            io.stdout.write(sha + "\n"); return 0
        case "log", "show":
            if let f = a.first(where: { $0.hasPrefix("--format=") || $0.hasPrefix("--pretty=") }) {
                let fmt = String(f.split(separator: "=", maxSplits: 1).last ?? "")
                let out = fmt.replacingOccurrences(of: "%H", with: sha).replacingOccurrences(of: "%h", with: String(sha.prefix(7)))
                    .replacingOccurrences(of: "%s", with: "ActionsRunner import").replacingOccurrences(of: "%an", with: "runner")
                    .replacingOccurrences(of: "%ae", with: "runner@actionsrunner.local")
                    .replacingOccurrences(of: "%ct", with: String(Int(Date().timeIntervalSince1970)))
                    .replacingOccurrences(of: "%cI", with: ISO8601DateFormatter().string(from: Date()))
                io.stdout.write(out + "\n"); return 0
            }
            io.stdout.write("commit \(sha)\nAuthor: runner <runner@actionsrunner.local>\n\n    ActionsRunner import\n"); return 0
        case "rev-list":
            if a.contains("--count") { io.stdout.write("1\n") } else { io.stdout.write(sha + "\n") }
            return 0
        case "branch":
            if a.contains("--show-current") { io.stdout.write(branch + "\n") } else { io.stdout.write("* \(branch)\n") }
            return 0
        case "status":
            io.stdout.write(a.contains("--porcelain") ? "" : "On branch \(branch)\nnothing to commit, working tree clean\n"); return 0
        case "config", "fetch", "checkout", "submodule", "lfs", "remote", "add", "init", "clean", "reset", "safe.directory":
            return 0
        case "diff":
            return 0
        case "describe":
            io.stderr.write("fatal: No names found, cannot describe anything.\n"); return 128
        default:
            io.stderr.write("git \(sub): l'interprete integrato emula solo rev-parse/log/branch/status. Per git completo esegui lo step nella VM Linux.\n")
            return 1
        }
    }
}
