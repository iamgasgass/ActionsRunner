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

/// Log "appiattito" in righe singole, da inserire DIRETTAMENTE in un LazyVStack:
/// niente contenitori annidati né effetti vetro su viste alte migliaia di punti
/// (causa di altezze stimate male, testo che sborda e schede vuote).
enum LogPanel {
    enum Item: Identifiable {
        case line(LogLine, indent: Bool)
        case group(LogLine, expanded: Bool)

        var id: Int {
            switch self {
            case .line(let l, _): return l.id
            case .group(let l, _): return l.id
            }
        }
    }

    /// Righe visibili: i gruppi ##[group] chiusi nascondono il loro contenuto.
    static func items(_ lines: [LogLine], expandedGroups: Set<Int>) -> [Item] {
        var out: [Item] = []
        out.reserveCapacity(lines.count)
        var openGroup: Int?
        for l in lines {
            switch l.kind {
            case .groupStart:
                openGroup = l.id
                out.append(.group(l, expanded: expandedGroups.contains(l.id)))
            case .groupEnd:
                openGroup = nil
            default:
                if let g = openGroup {
                    if expandedGroups.contains(g) { out.append(.line(l, indent: true)) }
                } else {
                    out.append(.line(l, indent: false))
                }
            }
        }
        return out
    }
}

/// Una riga del pannello log: sfondo leggero continuo, angoli arrotondati solo alla prima e all'ultima.
struct LogPanelRow: View {
    let item: LogPanel.Item
    let isFirst: Bool
    let isLast: Bool
    let onToggleGroup: (Int) -> Void

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.top, isFirst ? 10 : 0)
            .padding(.bottom, isLast ? 10 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                UnevenRoundedRectangle(topLeadingRadius: isFirst ? 16 : 0, bottomLeadingRadius: isLast ? 16 : 0,
                                       bottomTrailingRadius: isLast ? 16 : 0, topTrailingRadius: isFirst ? 16 : 0,
                                       style: .continuous)
                    .fill(Color.glassLine.opacity(0.05))
            }
    }

    @ViewBuilder private var content: some View {
        switch item {
        case .line(let l, let indent):
            LogLineRow(line: l)
                .padding(.leading, indent ? 14 : 0)
                .textSelection(.enabled)
        case .group(let l, let expanded):
            Button { onToggleGroup(l.id) } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text(l.text).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
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

/// Editor di coppie nome/valore (secrets, variabili) in una scheda di vetro.
struct KeyValueEditor: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String = "key.fill"
    @Binding var values: [String: String]
    var secure = false
    @State private var newKey = ""
    @State private var newValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GlassSectionHeading(title: title, subtitle: subtitle, symbol: symbol)

            if !values.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(values.keys.sorted().enumerated()), id: \.element) { idx, k in
                        if idx > 0 { GlassDivider() }
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(k)
                                    .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                                Text(secure ? "••••••••" : (values[k] ?? ""))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Button(role: .destructive) {
                                withAnimation(.easeInOut(duration: 0.2)) { _ = values.removeValue(forKey: k) }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.red.opacity(0.85))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Elimina \(k)")
                        }
                        .padding(.vertical, 10)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .liquidGlassCard(cornerRadius: 18, borderOpacity: 0.10, shadow: false)
            }

            GlassFieldLabel("Nome")
            GlassTextFieldSurface {
                TextField("NOME", text: $newKey)
                    .font(.system(.subheadline, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }
            GlassFieldLabel("Valore")
            GlassTextFieldSurface {
                if secure {
                    SecureField("valore", text: $newValue)
                        .font(.system(.subheadline, design: .monospaced))
                } else {
                    TextField("valore", text: $newValue)
                        .font(.system(.subheadline, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            Button {
                let k = newKey.trimmingCharacters(in: .whitespaces)
                guard !k.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.2)) { values[k] = newValue }
                newKey = ""
                newValue = ""
            } label: {
                Label("Aggiungi", systemImage: "plus")
            }
            .buttonStyle(LiquidGlassButtonStyle())
            .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .glassSection()
    }
}
