import SwiftUI

// MARK: - Esecuzione locale

struct LocalRunView: View {
    let model: LocalRunModel
    @Environment(RunCenter.self) private var runs

    var body: some View {
        List {
            Section {
                HStack {
                    StatusIcon(status: model.status, conclusion: model.conclusion, size: 22)
                    VStack(alignment: .leading) {
                        Text(model.title).font(.headline)
                        Text("#\(model.runNumber) · \(model.event) · \(model.workflowPath)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let s = model.startedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(Format.duration((model.finishedAt ?? Date()).timeIntervalSince(s))).font(.caption.monospacedDigit())
                        }
                    }
                }
                if model.status != .completed {
                    Button(role: .destructive) { runs.cancel(model) } label: { Label("Annulla esecuzione", systemImage: "stop.fill") }
                }
            }

            Section("Job") {
                ForEach(model.jobs) { job in
                    NavigationLink {
                        LocalJobView(job: job)
                    } label: {
                        HStack {
                            StatusIcon(status: job.status, conclusion: job.conclusion)
                            VStack(alignment: .leading) {
                                Text(job.name)
                                if !job.runsOn.isEmpty { Text(job.runsOn).font(.caption2).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if let s = job.startedAt { Text(Format.duration((job.finishedAt ?? Date()).timeIntervalSince(s))).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        }
                    }
                }
            }

            if !model.annotations.isEmpty {
                Section("Annotazioni (\(model.annotations.count))") {
                    ForEach(model.annotations) { a in AnnotationRow(level: a.level, title: a.title, message: a.message, location: [a.context, a.file, a.line.map { "riga \($0)" }].compactMap { $0 }.joined(separator: " · ")) }
                }
            }

            let summaries = model.jobs.filter { !$0.summary.isEmpty }
            if !summaries.isEmpty {
                Section("Riepilogo") {
                    ForEach(summaries) { j in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(j.name).font(.caption.bold())
                            MarkdownText(j.summary)
                        }
                    }
                }
            }

            if !model.artifacts.isEmpty {
                Section("Artifact") {
                    ForEach(model.artifacts) { a in
                        HStack {
                            Label(a.name, systemImage: "doc.zipper")
                            Spacer()
                            Text(Format.bytes(a.size)).font(.caption).foregroundStyle(.secondary)
                            ShareLink(item: a.url) { Image(systemName: "square.and.arrow.up") }
                        }
                    }
                }
            }
            if let root = model.rootURL, model.status == .completed {
                Section {
                    NavigationLink {
                        FileBrowserView(root: root, url: root, title: "File della run")
                    } label: { Label("Sfoglia workspace e file temporanei", systemImage: "folder") }
                }
            }
        }
        .navigationTitle("Run locale")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LocalJobView: View {
    let job: JobRunModel
    @State private var expanded: Set<UUID> = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let m = job.matrix, !m.isEmpty {
                        Text("matrix: " + m.pairs.map { "\($0.key)=\($0.value.stringValue)" }.joined(separator: ", "))
                            .font(.caption.monospaced()).foregroundStyle(.purple).padding(.horizontal).padding(.bottom, 6)
                    }
                    ForEach(job.steps) { step in
                        VStack(alignment: .leading, spacing: 0) {
                            Button {
                                if expanded.contains(step.id) { expanded.remove(step.id) } else { expanded.insert(step.id) }
                            } label: {
                                HStack {
                                    Image(systemName: expanded.contains(step.id) ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 12)
                                    StatusIcon(status: step.status, conclusion: step.conclusion, size: 14)
                                    Text(step.name).font(.subheadline).lineLimit(2).multilineTextAlignment(.leading)
                                    if let n = step.note { Text(n).font(.caption2).padding(.horizontal, 5).background(Capsule().fill(.orange.opacity(0.2))) }
                                    Spacer()
                                    if step.status == .completed, let d = step.duration { Text(Format.duration(d)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if expanded.contains(step.id) {
                                LogLinesView(lines: step.lines)
                                    .padding(.horizontal)
                                    .padding(.bottom, 8)
                            }
                            Divider()
                        }
                        .id(step.id)
                    }
                    if !job.outputs.isEmpty {
                        VStack(alignment: .leading) {
                            Text("Output del job").font(.caption.bold())
                            ForEach(job.outputs.keys.sorted(), id: \.self) { k in
                                Text("\(k) = \(job.outputs[k] ?? "")").font(.caption.monospaced())
                            }
                        }.padding()
                    }
                }
            }
            .onChange(of: job.steps.count) { _, _ in
                // espande automaticamente lo step in esecuzione
                if let running = job.steps.last(where: { $0.status == .inProgress }) {
                    expanded.insert(running.id)
                    withAnimation { proxy.scrollTo(running.id, anchor: .top) }
                }
            }
            .onAppear {
                if let failed = job.steps.first(where: { $0.conclusion == .failure }) { expanded.insert(failed.id) }
                else if let running = job.steps.last(where: { $0.status == .inProgress }) { expanded.insert(running.id) }
            }
        }
        .navigationTitle(job.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

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

struct MarkdownText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("#") {
                    Text(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)).font(.headline)
                } else if let attr = try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                    Text(attr).font(.footnote)
                } else {
                    Text(line).font(.footnote)
                }
            }
        }
    }
}

// MARK: - Elenco esecuzioni

struct RunsView: View {
    @Environment(RunCenter.self) private var runs

    var body: some View {
        List {
            if runs.localRuns.isEmpty {
                ContentUnavailableView("Nessuna esecuzione", systemImage: "play.slash", description: Text("Avvia un workflow da un progetto."))
            }
            if !runs.localRuns.isEmpty {
                Section {
                    ForEach(runs.localRuns) { m in
                        NavigationLink { LocalRunView(model: m) } label: {
                            HStack {
                                StatusIcon(status: m.status, conclusion: m.conclusion)
                                VStack(alignment: .leading) {
                                    Text(m.title)
                                    Text("#\(m.runNumber) · \(m.event)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions { Button("Elimina", role: .destructive) { runs.removeLocal(m) } }
                    }
                }
            }
        }
        .navigationTitle("Esecuzioni")
    }
}
