import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var cacheMessage: String?
    @State private var accountLabel = GitHubAPI.stored == nil ? "non collegato" : "collegato"

    var body: some View {
        @Bindable var s = settings
        Form {
            Section {
                NavigationLink { GitHubAccountView() } label: {
                    LabeledContent("Account GitHub", value: accountLabel)
                }
            } header: { Text("GitHub") } footer: {
                Text("I workflow vengono eseguiti sui runner di GitHub (Ubuntu, Windows, macOS con Xcode); log, annotazioni e artifact arrivano nell'app.")
            }

            KeyValueEditor(title: "Secrets (secrets.*)", values: $s.localSecrets, secure: true)
            KeyValueEditor(title: "Variabili (vars.*)", values: $s.localVariables)
            Section {
                Text("Si copiano nel repository quando attivi \"Copia secrets e variabili\" prima di avviare una run. I secrets vengono cifrati sul dispositivo.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Spazio") {
                Button("Elimina gli artifact scaricati e i file temporanei") { clearCaches() }
                if let m = cacheMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
            }

            Section("Info") {
                LabeledContent("Versione", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                LabeledContent("Dipendenze esterne", value: "nessuna")
            }
        }
        .navigationTitle("Impostazioni")
        .onAppear { accountLabel = GitHubAPI.stored == nil ? "non collegato" : "collegato" }
    }

    private func clearCaches() {
        let fm = FileManager.default
        var freed: Int64 = 0
        for dir in [AppPaths.cloudArtifacts, AppPaths.temp] {
            freed += AppPaths.size(of: dir)
            try? fm.removeItem(at: dir)
        }
        cacheMessage = "Liberati \(Format.bytes(freed))"
    }
}
