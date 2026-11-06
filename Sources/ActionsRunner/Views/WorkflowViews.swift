import SwiftUI

struct WorkflowDetailView: View {
    let project: Project
    let workflow: Workflow
    @Environment(RunCenter.self) private var runs
    @Environment(AppSettings.self) private var settings
    @Environment(ProjectStore.self) private var store
    @State private var showLocal = false
    @State private var showCloud = false
    @State private var startedLocal: LocalRunModel?
    @State private var startedCloud: CloudRunSession?

    var body: some View {
        List {
            Section {
                Button { showLocal = true } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Esegui sul dispositivo").font(.headline)
                            Text("Interprete integrato: espressioni, matrix, needs, bash, artifact, cache. Niente toolchain esterne.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "iphone") }
                }
                Button { showCloud = true } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Esegui su GitHub (fedele)").font(.headline)
                            Text("Carica la repo e avvia il workflow sui runner reali (macOS/Linux/Windows), con log e artifact.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "cloud.fill") }
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
                CloudRunConfigView(project: project, workflow: workflow) { session in
                    showCloud = false
                    startedCloud = session
                }
            }
        }
        .navigationDestination(item: $startedLocal) { m in LocalRunView(model: m) }
        .navigationDestination(item: $startedCloud) { s in CloudRunView(session: s) }
    }
}

extension LocalRunModel: Hashable {
    static func == (a: LocalRunModel, b: LocalRunModel) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

extension CloudRunSession: Hashable {
    static func == (a: CloudRunSession, b: CloudRunSession) -> Bool { a.id == b.id }
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
                    Label("Il workflow non dichiara '\(event)': su GitHub non verrebbe avviato.", systemImage: "exclamationmark.triangle")
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
                Picker("Azioni non supportate", selection: $policy) {
                    ForEach(LocalRunOptions.UnsupportedPolicy.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Debug (ACTIONS_STEP_DEBUG)", isOn: $debug)
            }
            Section {
                Text("I secrets e le variabili locali si configurano in Impostazioni. Il token GitHub (se presente) è esposto come secrets.GITHUB_TOKEN e usato per scaricare le azioni composite.")
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
                    o.githubToken = settings.hasToken ? settings.token : nil
                    o.repositoryOwner = project.githubOwner ?? (settings.effectiveOwner.isEmpty ? "local" : settings.effectiveOwner)
                    o.repositoryName = project.githubRepo ?? Project.sanitizedRepoName(project.name)
                    o.actor = settings.login.isEmpty ? "ios-user" : settings.login
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
            if let b = project.githubBranch { ref = "refs/heads/\(b)" }
            inputs = DispatchInputsForm.defaults(workflow.dispatchInputs)
            policy = settings.unsupportedPolicy
            debug = settings.debugLogs
        }
    }
}

struct CloudRunConfigView: View {
    let project: Project
    let workflow: Workflow
    let onStart: (CloudRunSession) -> Void
    @Environment(RunCenter.self) private var runs
    @Environment(AppSettings.self) private var settings
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var trigger: CloudRunSession.TriggerMode = .automatic
    @State private var inputs: [String: String] = [:]
    @State private var branch = ""

    var body: some View {
        Form {
            if !settings.hasToken {
                Section {
                    Label("Configura un token GitHub in Impostazioni (scope: repo + workflow, oppure fine-grained con Contents, Actions, Workflows, Administration in scrittura).", systemImage: "key.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section("Destinazione") {
                LabeledContent("Repository", value: "\(project.githubOwner ?? (settings.effectiveOwner.isEmpty ? "<tuo account>" : settings.effectiveOwner))/\(project.githubRepo ?? Project.sanitizedRepoName(settings.repoPrefix + project.name))")
                TextField("Branch (vuoto = \(project.githubBranch ?? "default"))", text: $branch)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Il contenuto dello ZIP verrà caricato esattamente com'è (commit unico). Il repository viene creato se non esiste\(settings.privateRepos ? " (privato)" : "").")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Avvio") {
                Picker("Modalità", selection: $trigger) {
                    ForEach(CloudRunSession.TriggerMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                switch trigger {
                case .automatic: Text("Usa il push se il workflow ha 'on: push' compatibile col branch, altrimenti workflow_dispatch.").font(.caption)
                case .push: Text("Il workflow parte solo se 'on: push' corrisponde al branch.").font(.caption)
                case .dispatch: Text("Richiede 'on: workflow_dispatch' nel file.").font(.caption)
                }
                if !workflow.supportsDispatch && trigger == .dispatch {
                    Label("Questo workflow non dichiara workflow_dispatch", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            if workflow.supportsDispatch && !workflow.dispatchInputs.isEmpty && trigger != .push {
                Section("Input workflow_dispatch") { DispatchInputsForm(inputs: workflow.dispatchInputs, values: $inputs) }
            }
            if settings.syncSecrets {
                Section {
                    Text("Verranno sincronizzati \(settings.localSecrets.count) secrets (cifrati con sealed box) e \(settings.localVariables.count) variabili.")
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Esegui su GitHub")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Avvia") {
                    let s = runs.newCloudSession()
                    s.start(project: project, workflow: workflow, settings: settings, store: store,
                            trigger: trigger, inputs: inputs, branchOverride: branch.isEmpty ? nil : branch)
                    onStart(s)
                }
                .disabled(!settings.hasToken)
            }
        }
        .onAppear { inputs = DispatchInputsForm.defaults(workflow.dispatchInputs) }
    }
}
