import SwiftUI

struct AnnotationRow: View {
    let level: String
    let title: String?
    let message: String
    let location: String

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: level == "error" || level == "failure" ? "xmark.octagon.fill" : (level == "warning" ? "exclamationmark.triangle.fill" : "info.circle.fill"))
                .foregroundStyle(level == "error" || level == "failure" ? .red : (level == "warning" ? .orange : .blue))
            VStack(alignment: .leading, spacing: 2) {
                if let t = title, !t.isEmpty { Text(t).font(.footnote.bold()) }
                Text(message).font(.footnote).textSelection(.enabled)
                if !location.isEmpty { Text(location).font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }
}

// MARK: - Elenco esecuzioni

struct RunsView: View {
    @Environment(RunCenter.self) private var runs

    var body: some View {
        List {
            if runs.cloudRuns.isEmpty {
                ContentUnavailableView("Nessuna esecuzione", systemImage: "play.slash",
                                       description: Text("Apri un progetto, scegli un workflow e tocca \"Esegui su GitHub\"."))
            }
            ForEach(runs.cloudRuns) { m in
                NavigationLink { CloudRunView(model: m) } label: {
                    HStack {
                        StatusIcon(status: m.status, conclusion: m.conclusion)
                        VStack(alignment: .leading) {
                            Text(m.run?.displayTitle ?? m.title)
                            Text([m.repo, m.run.map { "#\($0.runNumber)" }, Format.relative.localizedString(for: m.createdAt, relativeTo: Date())]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .swipeActions { Button("Elimina", role: .destructive) { runs.removeCloud(m) } }
            }
        }
        .navigationTitle("Esecuzioni")
    }
}
