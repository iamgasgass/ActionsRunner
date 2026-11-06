import SwiftUI

struct WorkflowDetailView: View {
    let project: Project
    let workflow: Workflow
    @Environment(RunCenter.self) private var runs
    @Environment(AppSettings.self) private var settings
    @Environment(ProjectStore.self) private var store
    @State private var showLocal = false
    @State private var startedLocal: LocalRunModel?
    @State private var showCloud = false
    @State private var startedCloud: CloudRunModel?

    private var hasMacJobs: Bool {
        workflow.jobs.contains { j in
            (j.runsOn?.scalarString ?? j.runsOn?.toJSON(pretty: false) ?? "").lowercased().contains("macos")
        }
    }

    var body: some View {
        List {
            Section {
                Button { showLocal = true } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Esegui il workflow").font(.headline)
                            Text(LinuxVM.shared.isSupported
                                 ? "Tutto sul dispositivo: motore Actions + VM Linux (Alpine) per gli step run: e le azioni JavaScript."
                                 : "Tutto sul dispositivo con l'interprete integrato (VM Linux non inclusa in questa build).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "iphone") }
                }
                Button { showCloud = true } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Esegui su GitHub").font(.headline)
                            Text(hasMacJobs
                                 ? "Necessario per questo workflow: i job macOS (Xcode, SDK iOS, firma) girano sui Mac di GitHub. Log, annotazioni e artifact (es. IPA) arrivano nell'app."
                                 : "Sui runner reali di GitHub (Ubuntu, Windows, macOS con Xcode): log, annotazioni e artifact nell'app.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "cloud") }
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
        .sheet(isPresented: $showLocal) {
            NavigationStack {
                LocalRunConfigView(project: project, workflow: workflow) { model in
                    showLocal = false
                    startedLocal = model
                }
            }
        }
        .sheet(isPresented: $showCloud) {
            NavigationStack {
                CloudRunConfigView(project: store.project(project.id) ?? project, workflow: workflow) { model in
                    showCloud = false
                    startedCloud = model
                }
            }
        }
        .navigationDestination(item: $startedLocal) { m in LocalRunView(model: m) }
        .navigationDestination(item: $startedCloud) { m in CloudRunView(model: m) }
    }
}

extension LocalRunModel: Hashable {
    static func == (a: LocalRunModel, b: LocalRunModel) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
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

struct LocalRunConfigView: View {
    let project: Project
    let workflow: Workflow
    let onStart: (LocalRunModel) -> Void
    @Environment(RunCenter.self) private var runs
    @Environment(AppSettings.self) private var settings
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var event = "push"
    @State private var ref = "refs/heads/main"
    @State private var inputs: [String: String] = [:]
    @State private var onlyJob = ""
    @State private var debug = false
    @State private var policy: LocalRunOptions.UnsupportedPolicy = .fail
    @State private var engine: ShellEngine = .auto

    var body: some View {
        Form {
            Section("Evento") {
                Picker("Evento", selection: $event) {
                    ForEach(workflow.eventNames + (workflow.eventNames.contains("push") ? [] : ["push"]), id: \.self) { Text($0).tag($0) }
                }
                TextField("Ref", text: $ref).textInputAutocapitalization(.never).autocorrectionDisabled()
                let branch = ref.replacingOccurrences(of: "refs/heads/", with: "").replacingOccurrences(of: "refs/tags/", with: "")
                if let cfg = workflow.triggers[event], ["push", "pull_request", "pull_request_target"].contains(event),
                   !FilterPattern.triggerMatches(config: cfg, branch: branch, isTag: ref.hasPrefix("refs/tags/")) {
                    Label("Su GitHub questo evento non attiverebbe il workflow (filtri branches/tags). Verrà eseguito comunque.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if workflow.triggers[event] == nil {
                    Label("Il workflow non dichiara '\(event)': GitHub non lo avvierebbe per questo evento. Verrà eseguito comunque.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if event == "workflow_dispatch" && !workflow.dispatchInputs.isEmpty {
                Section("Input") { DispatchInputsForm(inputs: workflow.dispatchInputs, values: $inputs) }
            }
            Section("Opzioni") {
                Picker("Job", selection: $onlyJob) {
                    Text("Tutti").tag("")
                    ForEach(workflow.jobs, id: \.id) { Text($0.displayName).tag($0.id) }
                }
                Picker("Esecuzione degli step", selection: $engine) {
                    ForEach(ShellEngine.allCases) { Text($0.label).tag($0) }
                }
                Picker("Azioni non supportate", selection: $policy) {
                    ForEach(LocalRunOptions.UnsupportedPolicy.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Debug (ACTIONS_STEP_DEBUG)", isOn: $debug)
            }
            Section {
                Text("I secrets e le variabili si configurano in Impostazioni. Le azioni remote (uses: owner/repo@ref) vengono scaricate una volta e poi restano in cache: le esecuzioni successive funzionano anche offline.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Esecuzione locale")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Avvia") {
                    var o = LocalRunOptions(sourceURL: project.repoURL)
                    o.eventName = event
                    o.ref = ref
                    o.inputs = inputs
                    o.secrets = settings.localSecrets
                    o.variables = settings.localVariables
                    o.repositoryOwner = settings.repositoryOwner.isEmpty ? "local" : settings.repositoryOwner
                    o.repositoryName = Project.sanitizedRepoName(project.name)
                    o.actor = settings.actor.isEmpty ? "ios-user" : settings.actor
                    o.shellEngine = engine
                    o.vmMemoryMB = settings.vmMemoryMB
                    o.debug = debug || settings.debugLogs
                    o.onlyJob = onlyJob.isEmpty ? nil : onlyJob
                    o.unsupportedActions = policy
                    let m = runs.startLocal(project: project, workflow: workflow, options: o, store: store)
                    onStart(m)
                }
            }
        }
        .onAppear {
            event = workflow.eventNames.first { ["push", "workflow_dispatch", "pull_request"].contains($0) } ?? workflow.eventNames.first ?? "push"
            inputs = DispatchInputsForm.defaults(workflow.dispatchInputs)
            policy = settings.unsupportedPolicy
            engine = settings.shellEngine
            debug = settings.debugLogs
        }
    }
}
