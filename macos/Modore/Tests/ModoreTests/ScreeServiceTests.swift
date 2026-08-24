import XCTest
@testable import Modore

final class ScreeServiceTests: XCTestCase {
    // The destination becomes a real filesystem path component under the
    // app's own results directory, so this locks down the one piece of that
    // pipeline that's pure enough to unit test without a signed runtime.
    func testPreserveFilenameCombinesToolAndSourceStem() {
        let name = ScreeService.preserveFilename(
            tool: "Claude",
            source: "/Users/test/.claude/projects/p/abc123.jsonl"
        )
        XCTAssertEqual(name, "Claude-abc123.md")
    }

    func testPreserveFilenameIgnoresSourceDirectoryComponents() {
        let name = ScreeService.preserveFilename(
            tool: "Codex",
            source: "/Users/test/.codex/sessions/2026/08/rollout-1.jsonl"
        )
        XCTAssertEqual(name, "Codex-rollout-1.md")
    }

    // tool is one of scree's own fixed labels today, but this is a filename
    // builder -- it must not trust either input to already be filesystem-safe.
    func testPreserveFilenameSanitizesUnsafeCharacters() {
        let name = ScreeService.preserveFilename(
            tool: "VS Code",
            source: "/Users/test/weird name/session file.jsonl"
        )
        XCTAssertFalse(name.contains(" "))
        XCTAssertFalse(name.contains("/"))
        XCTAssertTrue(name.hasSuffix(".md"))
    }

    // Not reachable through scree.py's own output today (source is always a
    // real Path's string form), but JsonRead.string defaults a malformed or
    // missing "source" key to "" -- the filename builder must not produce a
    // bare "-session.md"-shaped name or an empty path component in that case.
    func testPreserveFilenameFallsBackWhenSourceIsEmpty() {
        let name = ScreeService.preserveFilename(tool: "Claude", source: "")
        XCTAssertEqual(name, "Claude-session.md")
    }

    func testPrivateQueryScratchFileIsOwnerOnly() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scree-query-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(ScreeService.writePrivateQuery("private phrase", to: url))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "private phrase")
    }
}

final class ScreeEvidenceResultTests: XCTestCase {
    private func decode(definitive: Bool, coverage: String = "complete") throws
        -> ScreeEvidenceResult {
        let scanned = definitive ? 20 : 12
        let unreadable = definitive ? 0 : 2
        let json = """
        {"query":"DerivedData","conversationMentions":[],
         "providerToolExecutions":[],"modoreCleanupReceipts":[],
         "filesystemObservations":[],"scannedSessions":\(scanned),"totalSessions":20,
         "unreadableSessions":\(unreadable),"coverage":"\(coverage)",
         "truncatedReason":\(coverage == "complete" ? "null" : "\"time\""),
         "definitive":\(definitive),"masked":true}
        """
        return try JSONDecoder().decode(ScreeEvidenceResult.self, from: Data(json.utf8))
    }

    func testFourKindsKeepTheirRequiredNaturalLanguageLabels() {
        XCTAssertEqual(
            ScreeEvidenceKind.allCases.map(\.label),
            ["언급됨", "실행 기록 있음", "Modore가 실행함", "후속 변화 관찰됨"]
        )
    }

    func testIncompleteEvidenceDoesNotTurnUnknownIntoNone() throws {
        let result = try decode(definitive: false, coverage: "truncated")
        XCTAssertFalse(result.matchSummary.contains("없습니다"))
        let note = try XCTUnwrap(result.coverageNote)
        XCTAssertTrue(note.contains("단정하지 않습니다"))
        XCTAssertTrue(note.contains("12/20"))
        XCTAssertTrue(note.contains("2"))
    }

    func testOnlyDefinitivePayloadMayStateNoMatchingRecord() throws {
        let result = try decode(definitive: true)
        XCTAssertTrue(result.matchSummary.contains("찾지 못했습니다"))
        XCTAssertNil(result.coverageNote)
    }
}
