import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var cacheMessage: String?

    var body: some View {
        @Bindable var s = settings
        Form {
            Section {
                Picker("Esecuzione degli step run:", selection: $s.shellEngine) {
                    ForEach(ShellEngine.allCases) { Text($0.label).tag($0) }
                }
                Stepper("Memoria VM: \(settings.vmMemoryMB) MB", value: $s.vmMemoryMB, in: 256...2048, step: 128)
                Toggle("Avvia la VM all'apertura dell'app", isOn: $s.bootVMOnLaunch)
                NavigationLink { VMStatusView() } label: {
                    LabeledContent("Stato VM Linux", value: LinuxVM.shared.state.label)
                }
            } header: { Text("Motore di esecuzione") } footer: {
                Text("La VM Linux (RISC-V 64, Alpine) gira interamente nell'app: bash, git, python, node e gli altri pacchetti inclusi sono programmi Linux veri. La memoria si applica al successivo avvio della VM.")
            }

            Section("Contesto simulato") {
                TextField("Owner del repository (github.repository_owner)", text: $s.repositoryOwner)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Utente (github.actor)", text: $s.actor)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }

            KeyValueEditor(title: "Secrets (secrets.*)", values: $s.localSecrets, secure: true)
            KeyValueEditor(title: "Variabili (vars.*)", values: $s.localVariables)

            Section("Esecuzione") {
                Picker("Azioni Docker / non eseguibili", selection: $s.unsupportedPolicy) {
                    ForEach(LocalRunOptions.UnsupportedPolicy.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Log di debug (ACTIONS_STEP_DEBUG)", isOn: $s.debugLogs)
                Button("Svuota cache (azioni scaricate, actions/cache, run)") { clearCaches() }
                if let m = cacheMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
            }

            Section("Info") {
                LabeledContent("Versione", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0")
                LabeledContent("Dipendenze esterne", value: "nessuna")
                LabeledContent("Account / token", value: "non richiesti")
            }
        }
        .navigationTitle("Impostazioni")
    }

    private func clearCaches() {
        let fm = FileManager.default
        var freed: Int64 = 0
        for dir in [AppPaths.actionsCache, AppPaths.cacheStore, AppPaths.localRuns, AppPaths.temp] {
            freed += AppPaths.size(of: dir)
            try? fm.removeItem(at: dir)
        }
        cacheMessage = "Liberati \(Format.bytes(freed))"
    }
}

struct VMStatusView: View {
    private var vm: LinuxVM { LinuxVM.shared }
    @Environment(AppSettings.self) private var settings
    @State private var packages: [String] = []

    var body: some View {
        List {
            Section {
                LabeledContent("Stato", value: vm.state.label)
                if !vm.kernel.isEmpty { LabeledContent("Kernel", value: "Linux \(vm.kernel) (riscv64)") }
                if vm.state == .booting && !vm.bootStage.isEmpty { LabeledContent("Fase", value: vm.bootStage) }
                if vm.isReady {
                    LabeledContent("Cartella condivisa (9p)", value: vm.has9p ? "attiva" : "non disponibile")
                    LabeledContent("Rete (slirp)", value: vm.hasNetwork ? "attiva" : "non disponibile")
                    LabeledContent("Avvio", value: Format.duration(vm.bootSeconds))
                }
                if vm.state == .stopped {
                    Button("Avvia ora") {
                        let mem = settings.vmMemoryMB
                        Task.detached { try? await LinuxVM.shared.boot(memoryMB: mem) }
                    }
                }
            }
            if !packages.isEmpty {
                Section("Pacchetti Alpine inclusi (\(packages.count))") {
                    Text(packages.joined(separator: " ")).font(.caption.monospaced())
                }
            }
            Section("Console di avvio") {
                ForEach(Array(vm.bootLog.suffix(400).enumerated()), id: \.offset) { _, l in
                    Text(l).font(.caption2.monospaced()).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("VM Linux")
        .onAppear {
            if let u = Bundle.main.url(forResource: "packages", withExtension: "txt"),
               let t = try? String(contentsOf: u, encoding: .utf8) {
                packages = t.split(separator: "\n").map(String.init)
            }
        }
    }
}

/// Terminale semplice verso la VM Linux (un comando alla volta, la cartella corrente viene mantenuta).
struct TerminalView: View {
    @Environment(AppSettings.self) private var settings
    @State private var lines: [LogLine] = []
    @State private var command = ""
    @State private var cwd = "/root"
    @State private var running = false
    @State private var counter = 0

    private var vm: LinuxVM { LinuxVM.shared }

    var body: some View {
        VStack(spacing: 0) {
            if !vm.isSupported {
                ContentUnavailableView("VM Linux non inclusa", systemImage: "terminal",
                                       description: Text(LinuxVM.unavailabilityReason() ?? ""))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(lines) { LogLineRow(line: $0) }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(.horizontal, 8)
                    }
                    .onChange(of: lines.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
                Divider()
                HStack {
                    Text("\(cwd) $").font(.footnote.monospaced()).foregroundStyle(.secondary)
                    TextField("comando", text: $command)
                        .font(.footnote.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(run)
                        .disabled(running)
                    if running {
                        Button { vm.interrupt() } label: { Image(systemName: "stop.circle.fill") }
                    } else {
                        Button(action: run) { Image(systemName: "return") }.disabled(command.isEmpty)
                    }
                }
                .padding(8)
            }
        }
        .navigationTitle("Linux")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { lines.removeAll() } label: { Image(systemName: "trash") }
            }
        }
    }

    private func append(_ text: String, _ kind: LogLine.Kind) {
        counter += 1
        lines.append(LogLine(id: counter, text: text, kind: kind, date: Date()))
        if lines.count > 5000 { lines.removeFirst(lines.count - 5000) }
    }

    private func run() {
        let cmd = command.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty, !running else { return }
        command = ""
        append("\(cwd) $ \(cmd)", .command)
        running = true
        let dir = cwd
        let mem = settings.vmMemoryMB
        Task {
            do {
                if !LinuxVM.shared.isReady { append("Avvio della VM…", .info) }
                try await LinuxVM.shared.boot(memoryMB: mem)
                let script = "cd \(LinuxVM.shQuote(dir)) 2>/dev/null || cd /root\nexport HOME=/root TERM=dumb\n\(cmd)\nrc=$?\necho \"__AR_CWD__$(pwd)\"\nexit $rc"
                let rc = try await LinuxVM.shared.runCommandLine(script) { line in
                    DispatchQueue.main.async {
                        if line.hasPrefix("__AR_CWD__") { cwd = String(line.dropFirst(10)) } else { append(line, .output) }
                    }
                }
                if rc != 0 { append("exit \(rc)", .warning) }
            } catch {
                append(error.localizedDescription, .error)
            }
            running = false
        }
    }
}
