import SwiftUI
import UIKit

@main
struct ActionsRunnerApp: App {
    @State private var store = ProjectStore()
    @State private var settings = AppSettings()
    @State private var runs = RunCenter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(settings)
                .environment(runs)
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    Task { _ = await store.importItem(at: url) }
                }
        }
    }
}

struct RootView: View {
    @State private var selection = 0

    var body: some View {
        ZStack {
            AppGlassBackground()

            TabView(selection: $selection) {
                NavigationStack { ProjectsView() }
                    .tabItem { Label("Progetti", systemImage: "shippingbox.fill") }
                    .tag(0)
                NavigationStack { RunsView() }
                    .tabItem { Label("Esecuzioni", systemImage: "play.circle.fill") }
                    .tag(1)
                NavigationStack { SettingsView() }
                    .tabItem { Label("Impostazioni", systemImage: "slider.horizontal.3") }
                    .tag(2)
            }
            .tint(.white)
        }
        .preferredColorScheme(.dark)
    }
}

/// Tiene vive le esecuzioni su GitHub mentre si naviga nell'app.
@MainActor
@Observable
final class RunCenter {
    var cloudRuns: [CloudRunModel] = []
    @ObservationIgnored private var engines: [UUID: CloudRunEngine] = [:]

    init() {
        restoreCloudRuns()
    }

    // MARK: Esecuzioni su GitHub

    /// Avvia una run su GitHub (caricamento del progetto, avvio, monitoraggio).
    func startCloud(_ request: CloudRunRequest, api: GitHubAPI) -> CloudRunModel {
        let model = CloudRunModel(repo: request.repo, workflowPath: request.workflowPath, branch: request.branch,
                                  title: request.title, projectId: request.projectId)
        cloudRuns.insert(model, at: 0)
        let engine = CloudRunEngine(model: model, api: api)
        engine.onChange = { [weak self] in self?.saveCloudRuns() }
        engines[model.id] = engine
        engine.start(request)
        saveCloudRuns()
        return model
    }

    func engine(for model: CloudRunModel) -> CloudRunEngine? {
        if let e = engines[model.id] { return e }
        guard let api = GitHubAPI.stored else { return nil }
        let e = CloudRunEngine(model: model, api: api)
        e.onChange = { [weak self] in self?.saveCloudRuns() }
        engines[model.id] = e
        return e
    }

    /// Riprende il monitoraggio di una run non ancora terminata (o ne ricarica lo stato finale).
    func refreshCloud(_ model: CloudRunModel) {
        guard model.runId != nil, let e = engine(for: model), !e.isActive else { return }
        if case .failed = model.phase { return }
        if model.phase == .finished && !model.jobs.isEmpty && model.jobs.allSatisfy({ $0.logState == .complete }) { return }
        e.resume()
    }

    func removeCloud(_ model: CloudRunModel) {
        engines[model.id]?.stop()
        engines.removeValue(forKey: model.id)
        cloudRuns.removeAll { $0.id == model.id }
        if let id = model.runId { try? FileManager.default.removeItem(at: AppPaths.cloudArtifacts.appendingPathComponent("\(id)")) }
        saveCloudRuns()
    }

    func saveCloudRuns() {
        CloudRunRecord.saveAll(cloudRuns.map(\.record))
    }

    private func restoreCloudRuns() {
        let records = CloudRunRecord.loadAll()
        cloudRuns = records.map { r in
            let m = CloudRunModel(id: r.id, repo: r.repo, workflowPath: r.workflowPath, branch: r.branch, title: r.title,
                                  projectId: r.projectId, createdAt: r.createdAt)
            m.commitSha = r.commitSha
            m.runId = r.runId
            m.setupLog = r.setupLog ?? []
            if let f = r.failure { m.phase = .failed(f) } else if r.runId != nil { m.phase = .running } else { m.phase = .failed("interrotta prima dell'avvio della run") }
            return m
        }
        // riprende subito solo le run recenti; le altre si aggiornano quando vengono aperte
        for m in cloudRuns where m.runId != nil && Date().timeIntervalSince(m.createdAt) < 86_400 * 2 {
            if case .failed = m.phase { continue }
            refreshCloud(m)
        }
    }
}
