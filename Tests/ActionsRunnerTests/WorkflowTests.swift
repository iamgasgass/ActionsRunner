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
