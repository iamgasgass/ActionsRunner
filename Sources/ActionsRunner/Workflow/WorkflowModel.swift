import Foundation

struct Diagnostic: Identifiable, Hashable {
    enum Severity: String { case error, warning, info }
    let id = UUID()
    let severity: Severity
    let message: String
    var location: String? = nil
}

/// Rappresentazione di un file di workflow `.github/workflows/*.yml`.
struct Workflow: Identifiable {
    var id: String { path }
    let path: String            // percorso relativo alla repo, es. .github/workflows/build.yml
    let fileName: String
    let raw: OrderedObject
    let name: String
    let runName: String?
    let triggers: OrderedObject // evento -> configurazione (null se senza filtri)
    let env: JSONValue?
    let defaults: JSONValue?
    let permissions: JSONValue?
    let concurrency: JSONValue?
    let jobs: [Job]
    var diagnostics: [Diagnostic]

    var eventNames: [String] { triggers.keys }
    var supportsDispatch: Bool { triggers["workflow_dispatch"] != nil }
    var isReusable: Bool { triggers["workflow_call"] != nil }

    func job(_ id: String) -> Job? { jobs.first { $0.id == id } }

    /// Input dichiarati in on.workflow_dispatch.inputs.
    var dispatchInputs: [WorkflowInput] {
        guard let inputs = triggers["workflow_dispatch"]?["inputs"]?.objectValue else { return [] }
        return inputs.pairs.map { WorkflowInput(name: $0.key, spec: $0.value) }
    }

    var callInputs: [WorkflowInput] {
        guard let inputs = triggers["workflow_call"]?["inputs"]?.objectValue else { return [] }
        return inputs.pairs.map { WorkflowInput(name: $0.key, spec: $0.value) }
    }
}

struct WorkflowInput: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let description: String?
    let type: String           // string, boolean, choice, number, environment
    let required: Bool
    let defaultValue: JSONValue?
    let options: [String]

    init(name: String, spec: JSONValue) {
        self.name = name
        description = spec["description"]?.scalarString
        type = spec["type"]?.scalarString ?? "string"
        required = spec["required"]?.isTruthy ?? false
        defaultValue = spec["default"]
        options = spec["options"]?.arrayValue?.map { $0.stringValue } ?? []
    }

    static func == (a: WorkflowInput, b: WorkflowInput) -> Bool { a.name == b.name }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

struct Job: Identifiable {
    let id: String
    let raw: OrderedObject

    var name: String? { raw["name"]?.scalarString }
    var needs: [String] {
        switch raw["needs"] {
        case .string(let s)?: return [s]
        case .array(let a)?: return a.compactMap { $0.scalarString }
        default: return []
        }
    }
    var ifCondition: String? { Job.conditionString(raw["if"]) }
    var runsOn: JSONValue? { raw["runs-on"] }
    var strategy: JSONValue? { raw["strategy"] }
    var env: JSONValue? { raw["env"] }
    var defaults: JSONValue? { raw["defaults"] }
    var outputs: OrderedObject { raw["outputs"]?.objectValue ?? OrderedObject() }
    var timeoutMinutes: JSONValue? { raw["timeout-minutes"] }
    var continueOnError: JSONValue? { raw["continue-on-error"] }
    var container: JSONValue? { raw["container"] }
    var services: JSONValue? { raw["services"] }
    var environment: JSONValue? { raw["environment"] }
    var permissions: JSONValue? { raw["permissions"] }
    var concurrency: JSONValue? { raw["concurrency"] }
    /// Reusable workflow chiamato a livello di job.
    var uses: String? { raw["uses"]?.scalarString }
    var with: JSONValue? { raw["with"] }
    var secrets: JSONValue? { raw["secrets"] }

    var steps: [Step] {
        guard let arr = raw["steps"]?.arrayValue else { return [] }
        return arr.enumerated().compactMap { index, value in
            guard let o = value.objectValue else { return nil }
            return Step(index: index, raw: o)
        }
    }

    var displayName: String { name ?? id }

    static func conditionString(_ v: JSONValue?) -> String? {
        guard let v = v else { return nil }
        switch v {
        case .null: return nil
        case .bool(let b): return b ? "true" : "false"
        case .number(let d): return JSONValue.formatNumber(d)
        case .string(let s): return s
        default: return v.toJSON(pretty: false)
        }
    }
}

struct Step: Identifiable {
    let index: Int
    let raw: OrderedObject
    var id: String { stepId ?? "__step_\(index)" }

    var stepId: String? { raw["id"]?.scalarString }
    var name: String? { raw["name"]?.scalarString }
    var uses: String? { raw["uses"]?.scalarString }
    var run: String? { raw["run"]?.scalarString }
    var shell: String? { raw["shell"]?.scalarString }
    var with: OrderedObject { raw["with"]?.objectValue ?? OrderedObject() }
    var env: JSONValue? { raw["env"] }
    var workingDirectory: String? { raw["working-directory"]?.scalarString }
    var ifCondition: String? { Job.conditionString(raw["if"]) }
    var continueOnError: JSONValue? { raw["continue-on-error"] }
    var timeoutMinutes: JSONValue? { raw["timeout-minutes"] }

    /// Nome di default come lo mostra GitHub ("Run <prima riga>" o "Run <azione>").
    var defaultDisplayName: String {
        if let n = name { return n }
        if let u = uses { return "Run \(u)" }
        if let r = run {
            let first = r.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? r
            return "Run \(first.trimmingCharacters(in: .whitespaces))"
        }
        return "Step \(index + 1)"
    }
}
