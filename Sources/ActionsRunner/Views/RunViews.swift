import SwiftUI

struct AnnotationRow: View {
    let level: String
    let title: String?
    let message: String
    let location: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: level == "error" || level == "failure" ? "xmark.octagon.fill" : (level == "warning" ? "exclamationmark.triangle.fill" : "info.circle.fill"))
                .foregroundStyle(level == "error" || level == "failure" ? Color.red : (level == "warning" ? Color.orange : Color.white.opacity(0.8)))
            VStack(alignment: .leading, spacing: 3) {
                if let t = title, !t.isEmpty { Text(t).font(.footnote.bold()) }
                Text(message).font(.footnote).textSelection(.enabled)
                if !location.isEmpty {
                    Text(location).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .glassInset()
    }
}

// MARK: - Elenco esecuzioni

struct RunsView: View {
    @Environment(RunCenter.self) private var runs

    var body: some View {
        GlassList {
            if runs.cloudRuns.isEmpty {
                GlassEmptyState(symbol: "play.slash", title: "Nessuna esecuzione",
                                message: "Apri un progetto, scegli un workflow e tocca \"Esegui su GitHub\".")
                    .glassListRow()
            } else {
                GlassListHeader(title: "Su GitHub", count: runs.cloudRuns.count, symbol: "play.circle.fill")
                    .glassListRow()
            }
            ForEach(runs.cloudRuns) { m in
                CloudRunRow(model: m)
                    .overlay { NavigationLink { CloudRunView(model: m) } label: { EmptyView() }.opacity(0) }
                    .glassListRow()
                    .swipeActions { Button("Elimina", role: .destructive) { runs.removeCloud(m) } }
            }
        }
        .navigationTitle("Esecuzioni")
        .navigationBarTitleDisplayMode(.large)
    }
}

struct CloudRunRow: View {
    let model: CloudRunModel

    var body: some View {
        HStack(spacing: 14) {
            StatusIcon(status: model.status, conclusion: model.conclusion, size: 22)
                .frame(width: 48, height: 48)
                .background { Circle().fill(Color.white.opacity(0.075)) }
                .overlay { Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8) }
            VStack(alignment: .leading, spacing: 5) {
                Text(model.run?.displayTitle ?? model.title)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text([model.repo, model.run.map { "#\($0.runNumber)" }, Format.relative.localizedString(for: model.createdAt, relativeTo: Date())]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            GlassChevron()
        }
        .glassRow()
    }
}
