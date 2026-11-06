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
    var body: some View {
        TabView {
            NavigationStack { ProjectsView() }
                .tabItem { Label("Progetti", systemImage: "shippingbox") }
            NavigationStack { RunsView() }
                .tabItem { Label("Esecuzioni", systemImage: "play.circle") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Impostazioni", systemImage: "gearshape") }
        }
    }
}

/// Tiene vive le esecuzioni mentre si naviga nell'app.
@MainActor
@Observable
final class RunCenter {
    var localRuns: [LocalRunModel] = []
    var cloudSessions: [CloudRunSession] = []
    @ObservationIgnored private var runners: [UUID: LocalWorkflowRunner] = [:]
    @ObservationIgnored private var backgroundTasks: [UUID: UIBackgroundTaskIdentifier] = [:]

    func startLocal(project: Project, workflow: Workflow, options: LocalRunOptions, store: ProjectStore) -> LocalRunModel {
        var p = project
        p.localRunCounter += 1
        store.update(p)
        var opts = options
        opts.runNumber = p.localRunCounter
        let model = LocalRunModel(title: workflow.name, workflowPath: workflow.path, event: opts.eventName, runNumber: p.localRunCounter)
        let runner = LocalWorkflowRunner(workflow: workflow, options: opts, model: model)
        runners[model.id] = runner
        localRuns.insert(model, at: 0)
        let modelId = model.id
        let bgId = UIApplication.shared.beginBackgroundTask(withName: "local-run") { [weak self] in
            Task { @MainActor in self?.endBackground(modelId) }
        }
        backgroundTasks[model.id] = bgId
        Task.detached(priority: .userInitiated) { [weak self] in
            await runner.run()
            await self?.endBackground(modelId)
        }
        return model
    }

    private func endBackground(_ id: UUID) {
        if let t = backgroundTasks.removeValue(forKey: id), t != .invalid { UIApplication.shared.endBackgroundTask(t) }
    }

    func cancel(_ model: LocalRunModel) { runners[model.id]?.cancel() }

    func newCloudSession() -> CloudRunSession {
        let s = CloudRunSession()
        cloudSessions.insert(s, at: 0)
        return s
    }

    func removeLocal(_ model: LocalRunModel) {
        runners[model.id]?.cancel()
        runners.removeValue(forKey: model.id)
        localRuns.removeAll { $0.id == model.id }
        if let root = model.rootURL { try? FileManager.default.removeItem(at: root) }
    }
}
