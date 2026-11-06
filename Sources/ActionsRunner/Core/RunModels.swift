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
