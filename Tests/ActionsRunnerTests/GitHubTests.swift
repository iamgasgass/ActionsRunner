import XCTest
@testable import ActionsRunner

/// Vettori generati con libsodium (crypto_secretbox_easy, crypto_onetimeauth) e git (hash-object).
final class GitHubTests: XCTestCase {
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    func testPoly1305RFC() {
        let key: [UInt8] = Array(Data(hexString: "85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b")!)
        let tag = SealedBox.poly1305(key: key, message: Array("Cryptographic Forum Research Group".utf8))
        XCTAssertEqual(hex(tag), "a8061dc1305136c6c22b8baf0c0127a9")
    }

    func testBlake2b() {
        XCTAssertEqual(hex(SealedBox.blake2b([], outLength: 24)), "ab3b5331a7135ed50d0f182d026e60abdb3646fd51bcf8a3")
        XCTAssertEqual(hex(SealedBox.blake2b(Array("abc".utf8), outLength: 24)), "56a17e38cc371a46b12c32f18e0c61de2a84e9c2555b114e")
    }

    func testSecretboxMatchesLibsodium() {
        let key = (0..<32).map { UInt8($0) }
        let nonce = (100..<124).map { UInt8($0) }
        let unit = Array("ActionsRunner secret ✓ test 1234567890".utf8)
        let m = unit + unit + unit
        XCTAssertEqual(m.count, 120)
        let c = SealedBox.secretbox(m, nonce: nonce, key: key)
        XCTAssertEqual(hex(c), "47ac78dfacd29d77723cf9df1ec561cd43daeda055d8bdbbc5934df145a4d07d5dd85dd3c444d788867827e77eabf8ba9b5bc12e780fa2d4b475630b6f7dae37b4fec07d60a64a3a60933670fb5002f763ff291ebc1c79b88abb2ac477fbd4a315f4f96ec8910850e7f5e7420ac696a399bb8c0fcf3ba654230f1af8c87ca40a4b1ba37ce0137939")
    }

    func testSealedBoxShape() throws {
        let pk = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let sealed = try SealedBox.seal(Data("segreto".utf8), recipientPublicKey: pk)
        XCTAssertEqual(sealed.count, 7 + 48)
    }

    func testGitBlobSHA() {
        XCTAssertEqual(RepoUploader.blobSHA(Data("hello\n".utf8)), "ce013625030ba8dba906f756967f9e9ca394464a")
        XCTAssertEqual(RepoUploader.blobSHA(Data()), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
    }

    func testInlineTextDetection() {
        XCTAssertTrue(RepoUploader.isInlineText(Data("name: CI\r\non: push\n✓\n".utf8)))
        XCTAssertFalse(RepoUploader.isInlineText(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])))
        XCTAssertFalse(RepoUploader.isInlineText(Data([0xFF, 0xFE, 0x41])))
        XCTAssertFalse(RepoUploader.isInlineText(Data(repeating: 0x41, count: Int(RepoUploader.maxInlineSize) + 1)))
    }

    func testTreeTimeoutIsSplittable() {
        let timeout = GitHubError(status: 422, message: "Sorry, your request timed out.  It's likely that your input was too large to process.")
        XCTAssertTrue(RepoUploader.isTooLarge(timeout))
        XCTAssertTrue(RepoUploader.isTooLarge(GitHubError(status: 502, message: "Bad Gateway")))
        XCTAssertFalse(RepoUploader.isTooLarge(GitHubError(status: 422, message: "Invalid tree info")))
    }

    func testTreeEntryJSON() throws {
        let del = try RepoUploader.TreeEntry.delete(path: "a", mode: "100644", type: "blob").json()
        XCTAssertTrue(del["sha"] is NSNull)
        let data = try JSONSerialization.data(withJSONObject: ["tree": [del]])
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"sha\":null"))
    }

    func testDispatchResponseRunId() {
        let d1 = Data(#"{"workflow_run_id": 123456, "run_url": "https://api.github.com/repos/o/r/actions/runs/123456"}"#.utf8)
        XCTAssertEqual(GitHubActions.runId(fromDispatchResponse: d1), 123456)
        let d2 = Data(#"{"run_url": "https://api.github.com/repos/o/r/actions/runs/987"}"#.utf8)
        XCTAssertEqual(GitHubActions.runId(fromDispatchResponse: d2), 987)
        XCTAssertNil(GitHubActions.runId(fromDispatchResponse: Data()))
    }

    func testNextLink() {
        let h = #"<https://api.github.com/repositories/1/actions/runs/2/jobs?page=2>; rel="next", <https://api.github.com/x?page=5>; rel="last""#
        XCTAssertEqual(GitHubAPI.nextLink(h), "https://api.github.com/repositories/1/actions/runs/2/jobs?page=2")
        XCTAssertNil(GitHubAPI.nextLink(#"<https://a?page=1>; rel="prev""#))
    }

    func testJobLogSplitByStep() throws {
        let log = """
        2026-11-06T10:00:01.1234567Z ##[group]Runner Image
        2026-11-06T10:00:01.2234567Z Image: ubuntu-24.04
        2026-11-06T10:00:01.3234567Z ##[endgroup]
        2026-11-06T10:00:03.0000000Z ##[group]Run echo ciao
        2026-11-06T10:00:03.1000000Z ciao
        2026-11-06T10:00:05.9000000Z ##[error]Process completed with exit code 1.
        """
        let steps = [
            GHStep(name: "Set up job", status: "completed", conclusion: "success", number: 1,
                   startedAt: "2026-11-06T10:00:01Z", completedAt: "2026-11-06T10:00:02Z"),
            GHStep(name: "Run echo ciao", status: "completed", conclusion: "failure", number: 2,
                   startedAt: "2026-11-06T10:00:03.000+00:00", completedAt: "2026-11-06T10:00:06Z"),
        ]
        let parsed = GitHubJobLog.parse(log)
        XCTAssertEqual(parsed.count, 6)
        XCTAssertEqual(parsed[0].line.kind, .groupStart)
        XCTAssertEqual(parsed[0].line.text, "Runner Image")
        XCTAssertEqual(parsed[5].line.kind, .error)
        let split = GitHubJobLog.split(parsed, steps: steps)
        XCTAssertEqual(split[1]?.count, 3)
        XCTAssertEqual(split[2]?.count, 3)
        XCTAssertEqual(split[2]?[1].text, "ciao")
    }

    func testSecretNames() {
        XCTAssertTrue(GitHubActions.isValidName("API_KEY"))
        XCTAssertFalse(GitHubActions.isValidName("GITHUB_TOKEN"))
        XCTAssertFalse(GitHubActions.isValidName("1ABC"))
        XCTAssertFalse(GitHubActions.isValidName("A-B"))
    }
}

private extension Data {
    init?(hexString: String) {
        var bytes: [UInt8] = []
        var it = hexString.makeIterator()
        while let a = it.next(), let b = it.next() {
            guard let v = UInt8(String([a, b]), radix: 16) else { return nil }
            bytes.append(v)
        }
        self.init(bytes)
    }
}
