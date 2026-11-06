import SwiftUI

struct WorkflowDetailView: View {
    let project: Project
    let workflow: Workflow
    @Environment(ProjectStore.self) private var store
    @State private var showCloud = false
    @State private var startedCloud: CloudRunModel?

    var body: some View {
        List {
            Section {
                Button { showCloud = true } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Esegui su GitHub").font(.headline)
                            Text("Sui runner di GitHub (Ubuntu, Windows, macOS con Xcode): job, log, annotazioni e artifact (es. IPA) nell'app.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "play.circle.fill") }
                }
            }

            if !workflow.diagnostics.isEmpty {
                Section("Diagnostica (\(workflow.diagnostics.count))") {
                    ForEach(workflow.diagnostics) { d in
                        HStack(alignment: .top) {
                            Image(systemName: d.severity == .error ? "xmark.octagon.fill" : (d.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle"))
                                .foregroundStyle(d.severity == .error ? .red : (d.severity == .warning ? .orange : .blue))
                            VStack(alignment: .leading) {
                                Text(d.message).font(.footnote)
                                if let l = d.location { Text(l).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }

            Section("Eventi") {
                ForEach(workflow.triggers.keys, id: \.self) { ev in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ev).font(.body.monospaced())
                        if let cfg = workflow.triggers[ev], !cfg.isNull {
                            Text(cfg.toJSON(pretty: false)).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
            }

            Section("Job") {
                let levels = JobGraph.levels(workflow.jobs)
                ForEach(Array(levels.enumerated()), id: \.offset) { idx, level in
                    ForEach(level, id: \.id) { job in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("\(idx + 1)").font(.caption2.bold()).padding(4).background(Circle().fill(.blue.opacity(0.15)))
                                Text(job.displayName).font(.headline)
                            }
                            if let ro = job.runsOn { Text("runs-on: \(ro.scalarString ?? ro.toJSON(pretty: false))").font(.caption.monospaced()) }
                            if let u = job.uses { Text("uses: \(u)").font(.caption.monospaced()) }
                            if !job.needs.isEmpty { Text("needs: \(job.needs.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) }
                            if job.strategy?["matrix"] != nil {
                                let combos = (try? MatrixExpander.expand(job.strategy?["matrix"] ?? .null))?.count
                                Text("matrix: \(combos.map { "\($0) combinazioni" } ?? "dinamica")").font(.caption).foregroundStyle(.purple)
                            }
                            Text("\(job.steps.count) step").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Sorgente YAML") {
                NavigationLink {
                    FileViewer(url: project.repoURL.appendingPathComponent(workflow.path))
                } label: { Label(workflow.path, systemImage: "doc.text") }
            }
        }
        .navigationTitle(workflow.name)
        .sheet(isPresented: $showCloud) {
            NavigationStack {
                CloudRunConfigView(project: store.project(project.id) ?? project, workflow: workflow) { model in
                    showCloud = false
                    startedCloud = model
                }
            }
        }
        .navigationDestination(item: $startedCloud) { m in CloudRunView(model: m) }
    }
}

/// Form per gli input di workflow_dispatch.
struct DispatchInputsForm: View {
    let inputs: [WorkflowInput]
    @Binding var values: [String: String]

    var body: some View {
        ForEach(inputs) { input in
            VStack(alignment: .leading, spacing: 4) {
                switch input.type {
                case "boolean":
                    Toggle(isOn: Binding(get: { values[input.name] == "true" }, set: { values[input.name] = $0 ? "true" : "false" })) {
                        label(input)
                    }
                case "choice":
                    Picker(selection: Binding(get: { values[input.name] ?? "" }, set: { values[input.name] = $0 })) {
                        ForEach(input.options, id: \.self) { Text($0).tag($0) }
                    } label: { label(input) }
                default:
                    label(input)
                    TextField(input.defaultValue?.stringValue ?? "", text: Binding(get: { values[input.name] ?? "" }, set: { values[input.name] = $0 }))
                        .keyboardType(input.type == "number" ? .decimalPad : .default)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
        }
    }

    private func label(_ i: WorkflowInput) -> some View {
        VStack(alignment: .leading) {
            Text(i.name + (i.required ? " *" : "")).font(.subheadline.monospaced())
            if let d = i.description { Text(d).font(.caption).foregroundStyle(.secondary) }
        }
    }

    static func defaults(_ inputs: [WorkflowInput]) -> [String: String] {
        var d: [String: String] = [:]
        for i in inputs {
            if let v = i.defaultValue, !v.isNull { d[i.name] = v.stringValue }
            else if i.type == "boolean" { d[i.name] = "false" }
            else if i.type == "choice", let f = i.options.first { d[i.name] = f }
        }
        return d
    }
}
