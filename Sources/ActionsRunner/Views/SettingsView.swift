import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var tokenDraft = ""
    @State private var verifying = false
    @State private var verifyResult: String?
    @State private var cacheMessage: String?

    var body: some View {
        @Bindable var s = settings
        Form {
            Section {
                SecureField("ghp_… / github_pat_…", text: $tokenDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    Button("Salva token") {
                        settings.token = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        verify()
                    }
                    .disabled(tokenDraft.isEmpty)
                    Spacer()
                    if verifying { ProgressView() }
                    else if settings.hasToken { Button("Verifica") { verify() } }
                }
                if let r = verifyResult { Text(r).font(.caption) }
                if settings.hasToken {
                    Button("Rimuovi token", role: .destructive) { settings.token = ""; tokenDraft = ""; verifyResult = nil }
                }
            } header: { Text("Token GitHub") } footer: {
                Text("Token classic: scope **repo** e **workflow**. Fine-grained: Contents, Actions, Workflows, Secrets, Variables in lettura/scrittura e Administration (per creare repository). Il token è salvato nel Portachiavi.")
            }

            Section("Repository di destinazione") {
                TextField("Owner (vuoto = \(settings.login.isEmpty ? "il tuo utente" : settings.login))", text: $s.defaultOwner)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Prefisso nome repository", text: $s.repoPrefix)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Repository privati", isOn: $s.privateRepos)
                Toggle("Crea il repository se non esiste", isOn: $s.autoCreateRepo)
                Toggle("Sincronizza secrets e variabili prima dell'avvio", isOn: $s.syncSecrets)
            }

            KeyValueEditor(title: "Secrets (locali + sincronizzabili)", values: $s.localSecrets, secure: true)
            KeyValueEditor(title: "Variabili (vars.*)", values: $s.localVariables)

            Section("Esecuzione sul dispositivo") {
                Picker("Azioni JavaScript/Docker", selection: $s.unsupportedPolicy) {
                    ForEach(LocalRunOptions.UnsupportedPolicy.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Log di debug", isOn: $s.debugLogs)
                Button("Svuota cache (azioni scaricate, actions/cache, run locali)") { clearCaches() }
                if let m = cacheMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
            }

            Section("Come funziona") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("**Esegui su GitHub** — fedeltà totale: il contenuto dello ZIP viene caricato in un repository (Git Data API) e il workflow gira sui runner ufficiali GitHub (macOS con Xcode, Ubuntu, Windows). L'app segue la run, mostra i log, le annotazioni e scarica gli artifact (es. l'IPA).")
                    Text("**Esegui sul dispositivo** — iOS vieta di avviare processi esterni, quindi l'app include un motore completo: parser YAML, espressioni `${{ }}` (tutte le funzioni, incluso case()), contesti, matrix include/exclude, needs, if/always/failure, env/GITHUB_ENV/GITHUB_OUTPUT/GITHUB_PATH/STEP_SUMMARY, comandi ::, maschere dei secrets, azioni composite (anche remote), reusable workflow, checkout/artifact/cache emulati e un interprete bash con oltre 100 comandi. Gli strumenti di sistema (xcodebuild, node, docker…) non possono esistere su iOS: quegli step falliscono con un messaggio chiaro.")
                }
                .font(.footnote)
            }

            Section("Info") {
                LabeledContent("Versione", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                if !settings.tokenScopes.isEmpty { LabeledContent("Scope token", value: settings.tokenScopes.joined(separator: ", ")) }
            }
        }
        .navigationTitle("Impostazioni")
        .onAppear { tokenDraft = settings.token }
    }

    private func verify() {
        verifying = true
        verifyResult = nil
        let token = settings.token
        Task {
            do {
                let (user, scopes) = try await GitHubAPI(token: token).currentUser()
                settings.login = user.login
                settings.tokenScopes = scopes
                var msg = "✅ Autenticato come \(user.login)"
                if !scopes.isEmpty {
                    let missing = ["repo", "workflow"].filter { !scopes.contains($0) }
                    if !missing.isEmpty { msg += "\n⚠️ Scope mancanti: \(missing.joined(separator: ", "))" }
                } else {
                    msg += " (token fine-grained: verifica i permessi Contents/Actions/Workflows)"
                }
                verifyResult = msg
            } catch {
                verifyResult = "❌ \(error.localizedDescription)"
            }
            verifying = false
        }
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
