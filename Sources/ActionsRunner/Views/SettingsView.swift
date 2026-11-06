import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var cacheMessage: String?
    @State private var connected = GitHubAPI.stored != nil
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    var body: some View {
        @Bindable var s = settings
        GlassScreen(spacing: 16) {
            HStack(spacing: 15) {
                Image("AppMark")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 70, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.glassLine.opacity(0.20), lineWidth: 0.8)
                    }
                    .shadow(color: Color.glassShadow, radius: 11, x: 0, y: 5)

                VStack(alignment: .leading, spacing: 5) {
                    Text("ACTIONS RUNNER")
                        .font(.system(.caption, design: .rounded, weight: .heavy))
                        .tracking(1.8)
                        .foregroundStyle(.secondary)
                    Text("Control center")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                    Text("Account GitHub, aspetto, secrets e variabili")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassCard(cornerRadius: 28, borderOpacity: 0.18)

            VStack(alignment: .leading, spacing: 16) {
                GlassSectionHeading(
                    title: "Account GitHub",
                    subtitle: connected ? "Token collegato" : "Collega il tuo account per eseguire i workflow",
                    symbol: connected ? "person.crop.circle.badge.checkmark" : "person.crop.circle"
                )
                if connected {
                    GlassStatusPill(title: "Collegato", symbol: "checkmark.seal.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                NavigationLink { GitHubAccountView() } label: {
                    Label(connected ? "Gestisci il token" : "Collega con un token", systemImage: "key.fill")
                }
                .buttonStyle(LiquidGlassButtonStyle(prominent: !connected))
                Text("I workflow vengono eseguiti sui runner di GitHub (Ubuntu, Windows, macOS con Xcode); log, annotazioni e artifact arrivano nell'app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .glassSection()

            VStack(alignment: .leading, spacing: 14) {
                GlassSectionHeading(title: "Aspetto", subtitle: "Segui l'iPhone oppure scegli chiaro o scuro.",
                                    symbol: appearance.symbol)
                Picker("Aspetto", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { a in
                        Text(a.label).tag(a)
                    }
                }
                .pickerStyle(.segmented)
            }
            .glassSection()

            KeyValueEditor(title: "Secrets", subtitle: "secrets.* — cifrati sul dispositivo prima dell'invio.",
                           symbol: "lock.fill", values: $s.localSecrets, secure: true)
            KeyValueEditor(title: "Variabili", subtitle: "vars.* — copiate in chiaro nel repository.",
                           symbol: "textformat.abc", values: $s.localVariables)

            VStack(alignment: .leading, spacing: 16) {
                GlassSectionHeading(title: "Manutenzione", subtitle: "Libera spazio sul dispositivo.", symbol: "wrench.and.screwdriver")
                Button { clearCaches() } label: {
                    Label("Elimina artifact scaricati e file temporanei", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LiquidGlassButtonStyle())
                if let m = cacheMessage {
                    GlassStatusPill(title: m, symbol: "checkmark.circle.fill")
                }
                GlassDivider()
                GlassDetailRow(title: "Versione", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0", symbol: "info.circle")
                GlassDetailRow(title: "Dipendenze esterne", value: "nessuna", symbol: "shippingbox")
            }
            .glassSection()
        }
        .navigationTitle("Impostazioni")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { connected = GitHubAPI.stored != nil }
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
