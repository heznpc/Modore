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
         "providerToolInvocations":[],"modoreCleanupReceipts":[],
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
            ["언급됨", "Provider 도구 기록", "Modore 조치 기록", "후속 변화 관찰됨"]
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

    /// Query hits use their own event time, while query-independent storage
    /// records remain in a separate context list.
    func testTimelineUsesTurnTimestampAndSeparatesQueryMatchesFromContext() throws {
        let json = """
        {"query":"storage","conversationMentions":[
          {"source":"/Users/example/session.jsonl","tool":"Claude",
           "workspace":"/Users/example/work","lastActive":"2026-08-24 18:30",
           "lastActiveEpoch":1787563800,"at":"2026-08-24T09:30:00Z",
           "eventId":"turn-1","index":1,"role":"user",
           "isUser":true,"snippet":"storage"}],
         "providerToolInvocations":[
          {"kind":"provider_tool_invocation","command":"du -sh .","at":"2026-08-24T09:40:00.500Z",
           "callId":"call-1","status":"completed",
           "tool":"Codex","source":"/Users/example/tool.jsonl","workspace":"/Users/example/work",
           "lastActive":"2026-08-24 18:41","lastActiveEpoch":1787564460}],
         "modoreCleanupReceipts":[],
         "filesystemObservations":[
          {"kind":"filesystem_observation","at":"2026-08-24T09:45:00Z",
           "freeKB":1000,"dropKB":0,"status":"normal"}],
         "scannedSessions":1,"totalSessions":1,"unreadableSessions":0,
         "coverage":"complete","truncatedReason":null,"definitive":true,"masked":true}
        """
        let result = try JSONDecoder().decode(ScreeEvidenceResult.self, from: Data(json.utf8))
        let queryItems = StorageEvidenceTimelineItem.queryItems(from: result)
        let contextItems = StorageEvidenceTimelineItem.contextItems(from: result)

        XCTAssertEqual(
            queryItems.map(\.evidenceLabel),
            ["실행 완료 기록", "언급됨"]
        )
        XCTAssertEqual(queryItems[0].occurredAt, Date(timeIntervalSince1970: 1_787_564_400.5))
        XCTAssertEqual(queryItems[1].occurredAt, Date(timeIntervalSince1970: 1_787_563_800))
        XCTAssertEqual(contextItems.map(\.evidenceLabel), ["후속 변화 관찰됨"])
    }

    func testTimelineKeepsMalformedTimesExplicitlyUnknownAndLast() throws {
        let json = """
        {"query":"storage","conversationMentions":[],"providerToolInvocations":[],
         "modoreCleanupReceipts":[
          {"kind":"modore_cleanup_receipt","at":"not-a-date","recipeId":"cache",
           "label":"cache","status":"complete","estimatedKB":null}],
         "filesystemObservations":[
          {"kind":"filesystem_observation","at":"2026-08-24T09:45:00Z",
           "freeKB":1000,"dropKB":0,"status":"normal"}],
         "scannedSessions":0,"totalSessions":0,"unreadableSessions":0,
         "coverage":"complete","truncatedReason":null,"definitive":true,"masked":true}
        """
        let result = try JSONDecoder().decode(ScreeEvidenceResult.self, from: Data(json.utf8))
        let items = StorageEvidenceTimelineItem.contextItems(from: result)

        XCTAssertNotNil(items.first?.occurredAt)
        XCTAssertNil(items.last?.occurredAt)
        XCTAssertEqual(items.last?.displayTime, "시각 확인 안 됨")
    }

    func testConversationHitNeverFallsBackToResumedSessionTime() throws {
        let json = """
        {"query":"storage","conversationMentions":[
          {"source":"/Users/example/session.jsonl","tool":"Claude",
           "workspace":"/Users/example/work","lastActive":"2026-08-24 18:30",
           "lastActiveEpoch":1787563800,"at":null,"eventId":null,
           "index":1,"role":"user","isUser":true,"snippet":"storage"}],
         "providerToolInvocations":[],"modoreCleanupReceipts":[],
         "filesystemObservations":[],"scannedSessions":1,"totalSessions":1,
         "unreadableSessions":0,"coverage":"complete","truncatedReason":null,
         "definitive":true,"masked":true}
        """
        let result = try JSONDecoder().decode(ScreeEvidenceResult.self, from: Data(json.utf8))
        let item = try XCTUnwrap(StorageEvidenceTimelineItem.queryItems(from: result).first)
        XCTAssertNil(item.occurredAt)
        XCTAssertEqual(item.displayTime, "시각 확인 안 됨")
    }

    func testBlockedReceiptIsNeutralAndKeepsMeasuredAmountsSeparate() throws {
        let json = """
        {"query":"storage","conversationMentions":[],"providerToolInvocations":[],
         "modoreCleanupReceipts":[
          {"kind":"modore_cleanup_receipt","at":"2026-08-24T09:45:00Z",
           "recipeId":"cache","label":"캐시","status":"blocked",
           "estimatedKB":3000,"reclaimedKB":0,"physicalDeltaKB":0}],
         "filesystemObservations":[],"scannedSessions":0,"totalSessions":0,
         "unreadableSessions":0,"coverage":"complete","truncatedReason":null,
         "definitive":true,"masked":true}
        """
        let result = try JSONDecoder().decode(ScreeEvidenceResult.self, from: Data(json.utf8))
        let item = try XCTUnwrap(StorageEvidenceTimelineItem.contextItems(from: result).first)
        XCTAssertEqual(item.evidenceLabel, "Modore 조치 기록")
        XCTAssertTrue(item.detail.contains("실행 차단"))
        XCTAssertTrue(item.detail.contains("회수 기록"))
        XCTAssertTrue(item.detail.contains("가용 공간 변화"))
        XCTAssertTrue(item.detail.contains("사전 추정"))
    }
}
