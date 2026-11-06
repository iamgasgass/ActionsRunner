import SwiftUI

struct WorkflowDetailView: View {
    let project: Project
    let workflow: Workflow
    @Environment(ProjectStore.self) private var store
    @State private var showCloud = false
    @State private var startedCloud: CloudRunModel?

    var body: some View {
        GlassScreen {
            VStack(alignment: .leading, spacing: 14) {
                GlassSectionHeading(
                    title: workflow.name,
                    subtitle: "Sui runner di GitHub (Ubuntu, Windows, macOS con Xcode): job, log, annotazioni e artifact (es. IPA) nell'app.",
                    symbol: "gearshape.2"
                )

                VStack(alignment: .leading, spacing: 7) {
                    GlassFieldLabel("File")
                    Text(workflow.path)
                        .font(.system(.body, design: .monospaced, weight: .medium))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .glassInset()

                Button { showCloud = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill")
                        Text("Esegui su GitHub")
                    }
                }
                .buttonStyle(LiquidGlassButtonStyle(prominent: true))
            }
            .glassSection()

            if !workflow.diagnostics.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    GlassSectionHeading(title: "Diagnostica", subtitle: "\(workflow.diagnostics.count) segnalazioni prima dell'invio.",
                                        symbol: "stethoscope")
                    ForEach(workflow.diagnostics) { d in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: d.severity == .error ? "xmark.octagon.fill" : (d.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle"))
                                .foregroundStyle(d.severity == .error ? Color.red : (d.severity == .warning ? Color.orange : Color.white.opacity(0.8)))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(d.message).font(.footnote)
                                if let l = d.location {
                                    Text(l).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .glassInset()
                    }
                }
                .glassSection()
            }

            VStack(alignment: .leading, spacing: 12) {
                GlassSectionHeading(title: "Eventi", subtitle: "Quando GitHub avvia questo workflow.", symbol: "bolt.fill")
                ForEach(workflow.triggers.keys, id: \.self) { ev in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ev).font(.system(.subheadline, design: .monospaced, weight: .semibold))
                        if let cfg = workflow.triggers[ev], !cfg.isNull {
                            Text(cfg.toJSON(pretty: false))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    .glassInset()
                }
            }
            .glassSection()

            VStack(alignment: .leading, spacing: 12) {
                GlassSectionHeading(title: "Job", subtitle: "In ordine di esecuzione (needs).", symbol: "square.stack.3d.up.fill")
                let levels = JobGraph.levels(workflow.jobs)
                ForEach(Array(levels.enumerated()), id: \.offset) { idx, level in
                    ForEach(level, id: \.id) { job in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(idx + 1)")
                                .font(.system(.caption, design: .rounded, weight: .bold))
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Color.white.opacity(0.075)))
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(job.displayName).font(.system(.headline, design: .rounded, weight: .semibold))
                                if let ro = job.runsOn {
                                    Text("runs-on: \(ro.scalarString ?? ro.toJSON(pretty: false))").font(.system(.caption, design: .monospaced))
                                }
                                if let u = job.uses { Text("uses: \(u)").font(.system(.caption, design: .monospaced)) }
                                if !job.needs.isEmpty {
                                    Text("needs: \(job.needs.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                                }
                                if job.strategy?["matrix"] != nil {
                                    let combos = (try? MatrixExpander.expand(job.strategy?["matrix"] ?? .null))?.count
                                    Text("matrix: \(combos.map { "\($0) combinazioni" } ?? "dinamica")").font(.caption).foregroundStyle(.secondary)
                                }
                                Text("\(job.steps.count) step").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .glassInset()
                    }
                }
            }
            .glassSection()

            NavigationLink {
                FileViewer(url: project.repoURL.appendingPathComponent(workflow.path))
            } label: {
                Label("Sorgente YAML", systemImage: "doc.text")
            }
            .buttonStyle(LiquidGlassButtonStyle())
        }
        .navigationTitle(workflow.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCloud) {
            NavigationStack {
                CloudRunConfigView(project: store.project(project.id) ?? project, workflow: workflow) { model in
                    showCloud = false
                    startedCloud = model
                }
            }
            .presentationDetents([.large])
            .preferredColorScheme(.dark)
            .tint(.white)
        }
        .navigationDestination(item: $startedCloud) { m in CloudRunView(model: m) }
    }
}

/// Input di workflow_dispatch in superfici di vetro.
struct DispatchInputsForm: View {
    let inputs: [WorkflowInput]
    @Binding var values: [String: String]

    var body: some View {
        ForEach(inputs) { input in
            VStack(alignment: .leading, spacing: 8) {
                switch input.type {
                case "boolean":
                    Toggle(isOn: Binding(get: { values[input.name] == "true" }, set: { values[input.name] = $0 ? "true" : "false" })) {
                        label(input)
                    }
                    .tint(.white)
                case "choice":
                    label(input)
                    GlassTextFieldSurface {
                        Picker(input.name, selection: Binding(get: { values[input.name] ?? "" }, set: { values[input.name] = $0 })) {
                            ForEach(input.options, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .tint(.white)
                    }
                default:
                    label(input)
                    GlassTextFieldSurface {
                        TextField(input.defaultValue?.stringValue ?? "", text: Binding(get: { values[input.name] ?? "" }, set: { values[input.name] = $0 }))
                            .font(.system(.subheadline, design: .monospaced))
                            .keyboardType(input.type == "number" ? .decimalPad : .default)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
            }
        }
    }

    private func label(_ i: WorkflowInput) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(i.name + (i.required ? " *" : ""))
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(.secondary)
            if let d = i.description {
                Text(d).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
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
