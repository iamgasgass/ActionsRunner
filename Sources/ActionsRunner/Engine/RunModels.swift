import Foundation
import Observation

enum RunStatus: String, Codable {
    case queued, waiting, inProgress = "in_progress", completed

    var label: String {
        switch self {
        case .queued: return "In coda"
        case .waiting: return "In attesa"
        case .inProgress: return "In esecuzione"
        case .completed: return "Completato"
        }
    }
}

enum Conclusion: String, Codable {
    case success, failure, cancelled, skipped, neutral, timedOut = "timed_out", actionRequired = "action_required", stale, startupFailure = "startup_failure"

    init?(api: String?) {
        guard let s = api, let c = Conclusion(rawValue: s) else { return nil }
        self = c
    }

    var label: String {
        switch self {
        case .success: return "Riuscito"
        case .failure: return "Fallito"
        case .cancelled: return "Annullato"
        case .skipped: return "Saltato"
        case .neutral: return "Neutro"
        case .timedOut: return "Timeout"
        case .actionRequired: return "Azione richiesta"
        case .stale: return "Obsoleto"
        case .startupFailure: return "Errore di avvio"
        }
    }
}

struct LogLine: Identifiable, Hashable {
    enum Kind: String { case output, stderr, command, error, warning, notice, debug, groupStart, groupEnd, info, section }
    let id: Int
    let text: String
    let kind: Kind
    let date: Date
}

struct RunAnnotation: Identifiable, Hashable {
    let id = UUID()
    let level: String       // error, warning, notice
    let message: String
    var title: String? = nil
    var file: String? = nil
    var line: Int? = nil
    var context: String? = nil
}

@Observable
final class StepRunModel: Identifiable {
    let id = UUID()
    var name: String
    var status: RunStatus = .queued
    var conclusion: Conclusion?
    var outcome: Conclusion?
    var lines: [LogLine] = []
    var startedAt: Date?
    var finishedAt: Date?
    var note: String?
    var isPost = false
    @ObservationIgnored var nextLineId = 0

    init(name: String) { self.name = name }

    var duration: TimeInterval? {
        guard let s = startedAt else { return nil }
        return (finishedAt ?? Date()).timeIntervalSince(s)
    }
}

@Observable
final class JobRunModel: Identifiable {
    let id = UUID()
    let jobId: String
    var name: String
    var status: RunStatus = .queued
    var conclusion: Conclusion?
    var steps: [StepRunModel] = []
    var outputs: [String: String] = [:]
    var summary = ""
    var runsOn = ""
    var startedAt: Date?
    var finishedAt: Date?
    var matrix: OrderedObject?

    init(jobId: String, name: String) {
        self.jobId = jobId
        self.name = name
    }
}

struct LocalArtifact: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let url: URL
    let size: Int64
    let fileCount: Int
}

@Observable
final class LocalRunModel: Identifiable {
    let id = UUID()
    var title: String
    let workflowPath: String
    var event: String
    var status: RunStatus = .queued
    var conclusion: Conclusion?
    var jobs: [JobRunModel] = []
    var artifacts: [LocalArtifact] = []
    var annotations: [RunAnnotation] = []
    var startedAt: Date?
    var finishedAt: Date?
    var runNumber: Int
    var rootURL: URL?

    init(title: String, workflowPath: String, event: String, runNumber: Int) {
        self.title = title
        self.workflowPath = workflowPath
        self.event = event
        self.runNumber = runNumber
    }
}

/// Esegue sul main thread in ordine FIFO (gli aggiornamenti dei log restano ordinati).
func onMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
}

enum ISODate {
    static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static func parse(_ s: String?) -> Date? { s.flatMap { formatter.date(from: $0) } }
}

/// Esegue in modo sincrono sul main thread (per leggere stato osservabile da un thread di lavoro).
func onMainSync(_ block: () -> Void) {
    if Thread.isMainThread { block() } else { DispatchQueue.main.sync(execute: block) }
}
