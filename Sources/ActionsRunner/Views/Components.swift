import SwiftUI

struct StatusIcon: View {
    let status: RunStatus
    let conclusion: Conclusion?
    var size: CGFloat = 16

    var body: some View {
        Group {
            if status != .completed {
                if status == .inProgress {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "clock").foregroundStyle(.secondary)
                }
            } else {
                switch conclusion {
                case .success?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failure?, .startupFailure?, .timedOut?: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                case .cancelled?: Image(systemName: "stop.circle.fill").foregroundStyle(.gray)
                case .skipped?: Image(systemName: "arrow.uturn.right.circle").foregroundStyle(.secondary)
                default: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: size))
        .frame(width: size + 4, height: size + 4)
    }
}

extension StatusIcon {
    init(api status: String?, conclusion: String?, size: CGFloat = 16) {
        let st: RunStatus
        switch status {
        case "completed": st = .completed
        case "in_progress": st = .inProgress
        case "waiting", "pending", "requested": st = .waiting
        default: st = .queued
        }
        self.init(status: st, conclusion: Conclusion(api: conclusion), size: size)
    }
}

enum Format {
    static func duration(_ t: TimeInterval?) -> String {
        guard let t = t, t >= 0 else { return "" }
        if t < 1 { return "<1s" }
        let s = Int(t)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    static func apiDuration(_ start: String?, _ end: String?) -> String {
        guard let s = ISODate.parse(start) else { return "" }
        let e = ISODate.parse(end) ?? Date()
        return duration(e.timeIntervalSince(s))
    }

    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

/// Vista log con gruppi comprimibili (come ##[group] su GitHub).
struct LogLinesView: View {
    let lines: [LogLine]
    @State private var expanded: Set<Int> = []

    private struct Block: Identifiable {
        let id: Int
        let title: LogLine?
        var lines: [LogLine]
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var current: Block? = nil
        var loose: [LogLine] = []
        func flushLoose() {
            if !loose.isEmpty { out.append(Block(id: loose[0].id, title: nil, lines: loose)); loose = [] }
        }
        for l in lines {
            switch l.kind {
            case .groupStart:
                if let c = current { out.append(c) }
                flushLoose()
                current = Block(id: l.id, title: l, lines: [])
            case .groupEnd:
                if let c = current { out.append(c); current = nil }
            default:
                if current != nil { current!.lines.append(l) } else { loose.append(l) }
            }
        }
        if let c = current { out.append(c) }
        flushLoose()
        return out
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(blocks) { block in
                if let title = block.title {
                    Button {
                        if expanded.contains(block.id) { expanded.remove(block.id) } else { expanded.insert(block.id) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: expanded.contains(block.id) ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                            Text(title.text).lineLimit(1)
                        }
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    if expanded.contains(block.id) {
                        ForEach(block.lines) { LogLineRow(line: $0).padding(.leading, 14) }
                    }
                } else {
                    ForEach(block.lines) { LogLineRow(line: $0) }
                }
            }
        }
        .textSelection(.enabled)
    }
}

struct LogLineRow: View {
    let line: LogLine
    var body: some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 0.5)
            .background(background)
    }

    private var color: Color {
        switch line.kind {
        case .error: return .red
        case .warning: return .orange
        case .notice: return .blue
        case .debug: return .purple
        case .command: return .teal
        case .info: return .secondary
        case .section: return .primary
        default: return .primary
        }
    }

    private var background: Color {
        switch line.kind {
        case .error: return .red.opacity(0.08)
        case .warning: return .orange.opacity(0.08)
        default: return .clear
        }
    }
}

/// Log testuale di GitHub (timestamp ISO + ##[group]) convertito in righe.
enum GitHubLogParser {
    static func parse(_ text: String) -> [LogLine] {
        var out: [LogLine] = []
        var id = 0
        for raw in text.components(separatedBy: "\n") {
            var line = raw
            if line.hasSuffix("\r") { line.removeLast() }
            // rimuove il timestamp iniziale "2026-11-06T01:02:03.4567890Z "
            if line.count > 29, line.dropFirst(4).first == "-", let space = line.firstIndex(of: " "),
               line.distance(from: line.startIndex, to: space) <= 30, line[line.index(before: space)] == "Z" {
                line = String(line[line.index(after: space)...])
            }
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            var kind: LogLine.Kind = .output
            if line.hasPrefix("##[group]") { kind = .groupStart; line = String(line.dropFirst(9)) }
            else if line.hasPrefix("##[endgroup]") { kind = .groupEnd; line = "" }
            else if line.hasPrefix("##[error]") { kind = .error; line = String(line.dropFirst(9)) }
            else if line.hasPrefix("##[warning]") { kind = .warning; line = String(line.dropFirst(11)) }
            else if line.hasPrefix("##[notice]") { kind = .notice; line = String(line.dropFirst(10)) }
            else if line.hasPrefix("##[debug]") { kind = .debug }
            else if line.hasPrefix("[command]") { kind = .command; line = String(line.dropFirst(9)) }
            out.append(LogLine(id: id, text: line, kind: kind, date: Date()))
            id += 1
        }
        return out
    }
}

struct KeyValueEditor: View {
    let title: String
    @Binding var values: [String: String]
    var secure = false
    @State private var newKey = ""
    @State private var newValue = ""

    var body: some View {
        Section(title) {
            ForEach(values.keys.sorted(), id: \.self) { k in
                HStack {
                    Text(k).font(.system(.body, design: .monospaced))
                    Spacer()
                    Text(secure ? "••••••" : (values[k] ?? "")).foregroundStyle(.secondary).lineLimit(1)
                }
                .swipeActions { Button("Elimina", role: .destructive) { values.removeValue(forKey: k) } }
            }
            HStack {
                TextField("NOME", text: $newKey)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                if secure { SecureField("valore", text: $newValue) } else { TextField("valore", text: $newValue).autocorrectionDisabled() }
                Button {
                    let k = newKey.trimmingCharacters(in: .whitespaces)
                    guard !k.isEmpty else { return }
                    values[k] = newValue
                    newKey = ""; newValue = ""
                } label: { Image(systemName: "plus.circle.fill") }
                .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
