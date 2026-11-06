import XCTest
@testable import ActionsRunner

final class ExpressionTests: XCTestCase {
    private func eval(_ s: String, _ ctx: EvaluationContext = EvaluationContext()) throws -> JSONValue {
        try ExpressionEvaluator.evaluate(s, ctx)
    }

    func testLooseEquality() throws {
        XCTAssertEqual(try eval("1 == '1'"), .bool(true))
        XCTAssertEqual(try eval("'abc' == 'ABC'"), .bool(true))
        XCTAssertEqual(try eval("null == 0"), .bool(true))
        XCTAssertEqual(try eval("true == 1"), .bool(true))
        XCTAssertEqual(try eval("'abc' > 1"), .bool(false))
        XCTAssertEqual(try eval("'' == 0"), .bool(true))
    }

    func testLogicalOperatorsReturnOperands() throws {
        XCTAssertEqual(try eval("true && 'x'"), .string("x"))
        XCTAssertEqual(try eval("'' || 'default'"), .string("default"))
        XCTAssertEqual(try eval("!0"), .bool(true))
    }

    func testFunctions() throws {
        XCTAssertEqual(try eval("contains(fromJSON('[\"a\",\"b\"]'), 'B')"), .bool(true))
        XCTAssertEqual(try eval("contains('Hello world', 'llo')"), .bool(true))
        XCTAssertEqual(try eval("startsWith('Hello', 'he')"), .bool(true))
        XCTAssertEqual(try eval("endsWith('Hello', 'LO')"), .bool(true))
        XCTAssertEqual(try eval("format('{0}-{1} {{x}}', 'a', 1)"), .string("a-1 {x}"))
        XCTAssertEqual(try eval("join(fromJSON('[1,2]'), '+')"), .string("1+2"))
        XCTAssertEqual(try eval("case(1 == 2, 'a', 'b')"), .string("b"))
        XCTAssertEqual(try eval("case(false, 'a', true, 'c', 'd')"), .string("c"))
        XCTAssertEqual(try eval("toJSON(fromJSON('{\"a\":1}'))"), .string("{\n  \"a\": 1\n}"))
        XCTAssertEqual(try eval("fromJSON('3.5')"), .number(3.5))
    }

    func testObjectFilter() throws {
        var ctx = EvaluationContext()
        ctx["github"] = try JSONValue.parse(json: #"{"event":{"commits":[{"id":"x"},{"id":"y"}]}}"#)
        XCTAssertEqual(try eval("github.event.commits.*.id", ctx), .array([.string("x"), .string("y")]))
        XCTAssertEqual(try eval("contains(github.event.commits.*.id, 'Y')", ctx), .bool(true))
        XCTAssertEqual(try eval("github['event'].commits[1].id", ctx), .string("y"))
        XCTAssertEqual(try eval("github.EVENT.commits[0].ID", ctx), .string("x"))
    }

    func testTemplates() throws {
        var ctx = EvaluationContext()
        ctx["matrix"] = .object(OrderedObject([("n", .number(2))]))
        XCTAssertEqual(try ExpressionTemplate.evaluate("a-${{ matrix.n }}-b", ctx), .string("a-2-b"))
        XCTAssertEqual(try ExpressionTemplate.evaluate("${{ matrix.n }}", ctx), .number(2))
        XCTAssertEqual(try ExpressionTemplate.evaluate("${{ '}}' }}", ctx), .string("}}"))
    }

    func testConditions() throws {
        var ctx = EvaluationContext()
        ctx.status = StatusState(succeeded: false, failed: true, cancelled: false)
        XCTAssertFalse(try ExpressionTemplate.evaluateCondition(nil, ctx))
        XCTAssertFalse(try ExpressionTemplate.evaluateCondition("true", ctx))
        XCTAssertTrue(try ExpressionTemplate.evaluateCondition("always()", ctx))
        XCTAssertTrue(try ExpressionTemplate.evaluateCondition("${{ failure() }}", ctx))
        XCTAssertFalse(try ExpressionTemplate.evaluateCondition("success()", ctx))
        ctx.status = StatusState()
        XCTAssertTrue(try ExpressionTemplate.evaluateCondition("${{ 1 == 1 }}", ctx))
    }

    func testSyntaxErrors() {
        XCTAssertThrowsError(try ExpressionParser.parse("a ==") )
        XCTAssertThrowsError(try ExpressionParser.parse("unknownFn(1)"))
        XCTAssertThrowsError(try ExpressionParser.parse("case(true, 1)"))
    }
}

final class MatrixTests: XCTestCase {
    func testDocumentationIncludeExample() throws {
        let yaml = """
        fruit: [apple, pear]
        animal: [cat, dog]
        include:
          - color: green
          - color: pink
            animal: cat
          - fruit: apple
            shape: circle
          - fruit: banana
          - fruit: banana
            animal: cat
        """
        let combos = try MatrixExpander.expand(try YAMLLoader.load(yaml))
        XCTAssertEqual(combos.count, 6)
        func has(_ pairs: [(String, String)]) -> Bool {
            combos.contains { c in c.count == pairs.count && pairs.allSatisfy { c[$0.0]?.stringValue == $0.1 } }
        }
        XCTAssertTrue(has([("fruit", "apple"), ("animal", "cat"), ("color", "pink"), ("shape", "circle")]))
        XCTAssertTrue(has([("fruit", "apple"), ("animal", "dog"), ("color", "green"), ("shape", "circle")]))
        XCTAssertTrue(has([("fruit", "pear"), ("animal", "cat"), ("color", "pink")]))
        XCTAssertTrue(has([("fruit", "pear"), ("animal", "dog"), ("color", "green")]))
        XCTAssertTrue(has([("fruit", "banana")]))
        XCTAssertTrue(has([("fruit", "banana"), ("animal", "cat")]))
    }

    func testExclude() throws {
        let yaml = """
        os: [a, b]
        v: [1, 2]
        exclude:
          - os: a
            v: 1
        """
        XCTAssertEqual(try MatrixExpander.expand(try YAMLLoader.load(yaml)).count, 3)
    }

    func testOrder() throws {
        let combos = try MatrixExpander.expand(try YAMLLoader.load("os: [x, y]\nn: [1, 2]"))
        XCTAssertEqual(combos.map { "\($0["os"]!.stringValue)\($0["n"]!.stringValue)" }, ["x1", "x2", "y1", "y2"])
    }
}

final class WorkflowParsingTests: XCTestCase {
    func testOnKeyIsNotBoolean() throws {
        let wf = try WorkflowParser.parse(text: """
        name: CI
        on:
          push:
            branches: [main]
          workflow_dispatch:
            inputs:
              flag:
                type: boolean
                default: true
        jobs:
          a:
            runs-on: ubuntu-latest
            steps:
              - run: echo hi
          b:
            needs: a
            runs-on: ubuntu-latest
            steps:
              - uses: actions/checkout@v6
        """, path: ".github/workflows/ci.yml")
        XCTAssertEqual(wf.eventNames, ["push", "workflow_dispatch"])
        XCTAssertTrue(wf.supportsDispatch)
        XCTAssertEqual(wf.dispatchInputs.first?.type, "boolean")
        XCTAssertEqual(wf.jobs.map { $0.id }, ["a", "b"])
        XCTAssertEqual(wf.job("b")?.needs, ["a"])
        XCTAssertTrue(wf.diagnostics.filter { $0.severity == .error }.isEmpty, "\(wf.diagnostics.map { $0.message })")
    }

    func testCycleDetected() throws {
        let wf = try WorkflowParser.parse(text: """
        on: push
        jobs:
          a: { runs-on: x, needs: b, steps: [ { run: echo } ] }
          b: { runs-on: x, needs: a, steps: [ { run: echo } ] }
        """, path: "w.yml")
        XCTAssertTrue(wf.diagnostics.contains { $0.message.contains("circolare") })
    }

    func testFilterPatterns() {
        XCTAssertTrue(FilterPattern.matches("feature/x", pattern: "feature/*"))
        XCTAssertFalse(FilterPattern.matches("feature/x/y", pattern: "feature/*"))
        XCTAssertTrue(FilterPattern.matches("feature/x/y", pattern: "feature/**"))
        XCTAssertTrue(FilterPattern.evaluate("main", patterns: ["**", "!dev"]))
        XCTAssertFalse(FilterPattern.evaluate("dev", patterns: ["**", "!dev"]))
    }

    func testEnvironmentFile() throws {
        let r = try EnvironmentFile.parse("a=1\nb<<EOF\nline1\nline2\nEOF\nc=x=y\n")
        XCTAssertEqual(r.map { $0.0 }, ["a", "b", "c"])
        XCTAssertEqual(r[1].1, "line1\nline2")
        XCTAssertEqual(r[2].1, "x=y")
    }

    func testWorkflowCommands() {
        let st = CommandState()
        if case .setOutput(let n, let v) = WorkflowCommands.process("::set-output name=a::b%0Ac", st) {
            XCTAssertEqual(n, "a"); XCTAssertEqual(v, "b\nc")
        } else { XCTFail() }
        _ = WorkflowCommands.process("::add-mask::topsecret", st)
        XCTAssertEqual(st.mask("x topsecret y"), "x *** y")
        if case .log(let k, _) = WorkflowCommands.process("::group::Build", st) { XCTAssertEqual(k, .groupStart) } else { XCTFail() }
        _ = WorkflowCommands.process("::stop-commands::tok", st)
        if case .log(let k, _) = WorkflowCommands.process("::group::x", st) { XCTAssertEqual(k, .output) } else { XCTFail() }
        _ = WorkflowCommands.process("::tok::", st)
        if case .log(let k, _) = WorkflowCommands.process("::endgroup::", st) { XCTAssertEqual(k, .groupEnd) } else { XCTFail() }
    }
}

final class ShellTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("shtest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func sh(_ script: String, errexit: Bool = false, env: [String: String] = [:]) async -> (Int32, String) {
        let state = ShellState()
        state.vars["PWD"] = dir.path
        state.vars["HOME"] = dir.path
        for (k, v) in env { state.vars[k] = v; state.exported.insert(k) }
        state.errexit = errexit
        let host = ShellHost()
        host.tempDir = dir.path
        host.homeDir = dir.path
        let out = BufferSink()
        let interp = ShellInterpreter(state: state, host: host)
        let st = await interp.run(script: script, io: ShIO(stdin: InputSource(""), stdout: out, stderr: out))
        return (st, out.text)
    }

    func testArithmeticAndLoops() async {
        var r = await sh("x=5; echo $((x*2 + 1))")
        XCTAssertEqual(r.1, "11\n")
        r = await sh("for i in a b c; do echo -n $i; done")
        XCTAssertEqual(r.1, "abc")
        r = await sh("i=0; while [ $i -lt 3 ]; do i=$((i+1)); done; echo $i")
        XCTAssertEqual(r.1, "3\n")
        r = await sh("for ((i=0; i<3; i++)); do echo -n $i; done")
        XCTAssertEqual(r.1, "012")
    }

    func testConditionalsAndCase() async {
        var r = await sh("if [ \"a\" = \"a\" ]; then echo yes; else echo no; fi")
        XCTAssertEqual(r.1, "yes\n")
        r = await sh("case foo in f*) echo match;; *) echo no;; esac")
        XCTAssertEqual(r.1, "match\n")
        r = await sh("[[ \"abc\" == a* ]] && echo ok")
        XCTAssertEqual(r.1, "ok\n")
        r = await sh("[[ \"v1.2.3\" =~ ^v([0-9]+) ]] && echo $BASH_REMATCH_1")
        XCTAssertEqual(r.1, "1\n")
    }

    func testParameterExpansion() async {
        var r = await sh("unset Z; echo ${Z:-def}")
        XCTAssertEqual(r.1, "def\n")
        r = await sh("v=hello.tar.gz; echo ${v%%.*} ${v#*.} ${v^^} ${#v}")
        XCTAssertEqual(r.1, "hello tar.gz HELLO.TAR.GZ 12\n")
        r = await sh("p=a/b/c; echo ${p//\\//-} ${p:2:3}")
        XCTAssertEqual(r.1, "a-b-c b/c\n")
    }

    func testSubstitutionHeredocAndFunctions() async {
        var r = await sh("echo \"x=$(echo inner)\"")
        XCTAssertEqual(r.1, "x=inner\n")
        r = await sh("X=1\ncat <<EOF\nhi $X\nEOF\ncat <<'EOF'\nraw $X\nEOF")
        XCTAssertEqual(r.1, "hi 1\nraw $X\n")
        r = await sh("f() { echo \"arg:$1\"; return 3; }; f z; echo $?")
        XCTAssertEqual(r.1, "arg:z\n3\n")
    }

    func testErrexit() async {
        let r = await sh("false\necho after", errexit: true)
        XCTAssertEqual(r.0, 1)
        XCTAssertEqual(r.1, "")
        let r2 = await sh("false || echo recovered\nif false; then :; fi\necho end", errexit: true)
        XCTAssertEqual(r2.0, 0)
        XCTAssertEqual(r2.1, "recovered\nend\n")
    }

    func testTextTools() async {
        var r = await sh("echo a b | tr a-z A-Z")
        XCTAssertEqual(r.1, "A B\n")
        r = await sh("printf '%s=%d\\n' x 5")
        XCTAssertEqual(r.1, "x=5\n")
        r = await sh("echo 'a,b,c' | cut -d, -f2")
        XCTAssertEqual(r.1, "b\n")
        r = await sh("echo hello | sed 's/l/L/g'")
        XCTAssertEqual(r.1, "heLLo\n")
        r = await sh("echo 'a b c' | awk '{print $2}'")
        XCTAssertEqual(r.1, "b\n")
        r = await sh("seq 3 | grep -c .")
        XCTAssertEqual(r.1, "3\n")
        r = await sh("printf 'a\\nb\\n' | while read l; do echo \"[$l]\"; done")
        XCTAssertEqual(r.1, "[a]\n[b]\n")
        r = await sh("printf 'b\\na\\nb\\n' | sort -u | wc -l")
        XCTAssertEqual(r.1.trimmingCharacters(in: .whitespacesAndNewlines), "2")
    }

    func testFilesAndRedirection() async {
        let r = await sh("mkdir -p d/e && echo k=v >> d/e/out.txt && echo z=1 >> d/e/out.txt && cat d/e/out.txt | head -n 1 && ls d")
        XCTAssertEqual(r.1, "k=v\ne\n")
        let r2 = await sh("echo err 1>&2 2>/dev/null; echo ok > f.txt; [ -f f.txt ] && cat f.txt")
        XCTAssertTrue(r2.1.hasSuffix("ok\n"))
        let r3 = await sh("xcodebuild -version")
        XCTAssertEqual(r3.0, 127)
        XCTAssertTrue(r3.1.contains("Esegui su GitHub"))
    }
}

final class YAMLParserTests: XCTestCase {
    func testBlockAndFlowStructures() throws {
        let y = try YAMLParser.parse("""
        # commento
        name: "CI: test"
        on:
          push:
            branches: [ main, 'release/**' ]   # commento
        env:
          B: "x # non commento"
          C: it's # commento
          D: >-
            piegato
            testo

            paragrafo
          E: |
            riga 1
              rientrata
          G: 3.10
          H: on
          URL: http://example.com:8080/x
        defaults: &defs
          run:
            shell: bash
        other:
          <<: *defs
          extra: yes
        jobs:
          build:
            steps:
            - uses: actions/checkout@v6
              with:
                fetch-depth: 0
            - run: echo plain
                continua
            -
              name: trattino vuoto
            - { name: flow, run: 'echo 1' }
        """)
        XCTAssertEqual(y["name"], .string("CI: test"))
        XCTAssertNotNil(y["on"]?["push"])
        XCTAssertEqual(y["on"]?["push"]?["branches"], .array([.string("main"), .string("release/**")]))
        XCTAssertEqual(y["env"]?["B"], .string("x # non commento"))
        XCTAssertEqual(y["env"]?["C"], .string("it's"))
        XCTAssertEqual(y["env"]?["D"], .string("piegato testo\nparagrafo"))
        XCTAssertEqual(y["env"]?["E"], .string("riga 1\n  rientrata\n"))
        XCTAssertEqual(y["env"]?["G"], .number(3.1))
        XCTAssertEqual(y["env"]?["H"], .string("on"))
        XCTAssertEqual(y["env"]?["URL"], .string("http://example.com:8080/x"))
        XCTAssertEqual(y["other"]?["run"]?["shell"], .string("bash"))
        XCTAssertEqual(y["other"]?["extra"], .string("yes"))
        let steps = y["jobs"]?["build"]?["steps"]?.arrayValue ?? []
        XCTAssertEqual(steps.count, 4)
        XCTAssertEqual(steps[0]["with"]?["fetch-depth"], .number(0))
        XCTAssertEqual(steps[1]["run"], .string("echo plain continua"))
        XCTAssertEqual(steps[2]["name"], .string("trattino vuoto"))
        XCTAssertEqual(steps[3]["run"], .string("echo 1"))
    }

    func testQuotedScalars() throws {
        let y = try YAMLParser.parse("""
        a: 'it''s'
        b: "tab\\tquote\\" é\\u00e9"
        c: "riga
          continua"
        "chiave: quotata": 1
        """)
        XCTAssertEqual(y["a"], .string("it's"))
        XCTAssertEqual(y["b"], .string("tab\tquote\" éé"))
        XCTAssertEqual(y["c"], .string("riga continua"))
        XCTAssertEqual(y["chiave: quotata"], .number(1))
    }

    func testChompingAndNestedSequences() throws {
        let y = try YAMLParser.parse("""
        keep: |+
          a

        strip: |-
          b
        list:
        - - x
          - y
        - z
        """)
        XCTAssertEqual(y["keep"], .string("a\n\n"))
        XCTAssertEqual(y["strip"], .string("b"))
        XCTAssertEqual(y["list"], .array([.array([.string("x"), .string("y")]), .string("z")]))
    }
}

final class ZipTests: XCTestCase {
    func testRoundTrip() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ziptest-\(UUID().uuidString)")
        let src = base.appendingPathComponent("src/sub")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        let big = String(repeating: "ActionsRunner ", count: 5000)
        try big.write(to: src.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho hi\n".write(to: src.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: src.appendingPathComponent("run.sh").path)
        let zip = base.appendingPathComponent("a.zip")
        try ZipUtil.zipDirectory(base.appendingPathComponent("src"), to: zip)
        let out = base.appendingPathComponent("out")
        try ZipUtil.unzip(zip, to: out)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("sub/big.txt"), encoding: .utf8), big)
        let perms = (try fm.attributesOfItem(atPath: out.appendingPathComponent("sub/run.sh").path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms.map { $0 & 0o111 != 0 }, true)
        XCTAssertLessThan((try fm.attributesOfItem(atPath: zip.path)[.size] as? NSNumber)?.intValue ?? .max, big.utf8.count)
        XCTAssertEqual(ZipUtil.crc32(Data("123456789".utf8)), 0xCBF43926)
        try? fm.removeItem(at: base)
    }
}

final class VMTests: XCTestCase {
    func testPathTranslation() {
        let root = LinuxVM.sharedRoot.path
        XCTAssertEqual(LinuxVM.guestPath(root + "/Runs/x/jobs/1/work", jobRoot: root + "/Runs/x/jobs/1"), "/home/runner/work")
        XCTAssertEqual(LinuxVM.guestPath(root + "/Actions/a/b"), "/mnt/host/Actions/a/b")
        XCTAssertEqual(LinuxVM.translate("cd \(root)/Runs/x/jobs/1/work && ls \(root)/Actions", jobRoot: root + "/Runs/x/jobs/1"),
                       "cd /home/runner/work && ls /mnt/host/Actions")
        XCTAssertEqual(LinuxVM.shQuote("it's"), "'it'\\''s'")
    }
}

final class LocalRunnerIntegrationTests: XCTestCase {
    func testMatrixNeedsAndOutputs() async throws {
        let yaml = """
        name: CI
        on: [push]
        env:
          GREETING: ciao
        jobs:
          build:
            runs-on: ubuntu-latest
            strategy:
              matrix:
                n: [1, 2]
            outputs:
              value: ${{ steps.calc.outputs.result }}
            steps:
              - id: calc
                run: echo "result=$(( ${{ matrix.n }} * 10 ))" >> "$GITHUB_OUTPUT"
              - run: echo "$GREETING ${{ steps.calc.outputs.result }}"
              - run: echo "FROM_ENV=yes" >> "$GITHUB_ENV"
              - run: test "$FROM_ENV" = "yes"
          report:
            needs: build
            runs-on: ubuntu-latest
            steps:
              - run: test "${{ needs.build.outputs.value }}" = "20"
              - if: failure()
                run: exit 1
        """
        let wf = try WorkflowParser.parse(text: yaml, path: ".github/workflows/ci.yml")
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        var opts = LocalRunOptions(sourceURL: src)
        opts.repositoryName = "test"
        opts.shellEngine = .builtin
        let model = LocalRunModel(title: "CI", workflowPath: wf.path, event: "push", runNumber: 1)
        let runner = LocalWorkflowRunner(workflow: wf, options: opts, model: model)
        await runner.run()
        await MainActor.run {}
        let conclusion = await MainActor.run { model.conclusion }
        let jobCount = await MainActor.run { model.jobs.count }
        let failedLogs = await MainActor.run {
            model.jobs.flatMap { $0.steps }.filter { $0.conclusion == .failure }.flatMap { $0.lines.map { $0.text } }
        }
        XCTAssertEqual(conclusion, .success, failedLogs.joined(separator: "\n"))
        XCTAssertEqual(jobCount, 3)
    }
}
