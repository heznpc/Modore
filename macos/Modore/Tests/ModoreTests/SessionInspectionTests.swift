import XCTest
import MothballCore
@testable import Modore

/// The display half of `inspect`. Everything here is a fact the Python
/// side already pins from its end; these fix that the app does not undo it
/// on the way to the screen.
final class SessionConversationDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> SessionConversation {
        try JSONDecoder().decode(SessionConversation.self, from: Data(json.utf8))
    }

    private func payload(status: String?, turns: String) -> String {
        let statusLine = status.map { "\"status\": \"\($0)\"," } ?? ""
        return """
        {
          \(statusLine)
          "provider": "claude",
          "sessionId": "s1",
          "workspace": "/Users/example/repo",
          "messageCount": 3,
          "userTurnCount": 2,
          "firstUserTurn": "다시 확인해줘",
          "turns": \(turns),
          "omittedTurns": 0,
          "masked": true
        }
        """
    }

    /// The case the dedupe rule deliberately preserves -- the same person
    /// saying the same thing twice with a reply in between -- is exactly
    /// where role-plus-text identity collides, and a `ForEach` given
    /// duplicate ids silently drops a turn out of the conversation.
    func test_repeatedTurnsKeepDistinctIdentities() throws {
        let conversation = try decode(payload(status: "ok", turns: """
        [
          {"index": 0, "role": "user", "text": "다시 확인해줘"},
          {"index": 1, "role": "assistant", "text": "확인했습니다"},
          {"index": 2, "role": "user", "text": "다시 확인해줘"}
        ]
        """))
        XCTAssertEqual(conversation.turns.count, 3)
        XCTAssertEqual(Set(conversation.turns.map(\.id)).count, 3,
                       "a genuine repeat must not collapse into one row")
        XCTAssertEqual(conversation.turns.map(\.id), [0, 1, 2])
    }

    func test_everyFailureStatusDecodesToItsOwnCase() throws {
        for (raw, expected) in [
            ("ok", SessionConversation.Status.ok),
            ("missing", .missing),
            ("unreadable", .unreadable),
            ("unrecognized", .unrecognized),
        ] {
            let conversation = try decode(payload(status: raw, turns: "[]"))
            XCTAssertEqual(conversation.status, expected)
        }
    }

    /// Three different reasons all produce zero turns. Showing them as an
    /// empty conversation tells someone about to retire a repo that there
    /// was nothing to lose, so each has to carry its own sentence.
    func test_failureStatusesEachExplainThemselves() throws {
        for raw in ["missing", "unreadable", "unrecognized"] {
            let conversation = try decode(payload(status: raw, turns: "[]"))
            XCTAssertTrue(conversation.turns.isEmpty)
            let text = conversation.status.failureText
            XCTAssertNotNil(text, "\(raw) must not render as an empty conversation")
            XCTAssertFalse(text!.isEmpty)
        }
        let ok = try decode(payload(status: "ok", turns: "[]"))
        XCTAssertNil(ok.status.failureText, "an empty session is not a failure")
    }

    /// A status this build has never heard of is still a session it cannot
    /// show -- decoding must degrade, not throw away the whole payload.
    func test_anUnknownStatusIsTreatedAsUnreadableRatherThanFailingTheDecode() throws {
        let conversation = try decode(payload(status: "quarantined", turns: "[]"))
        XCTAssertEqual(conversation.status, .unrecognized)
    }

    /// Payloads written before `inspect` reported status only ever came
    /// from a file it had just read.
    func test_anAbsentStatusDefaultsToOk() throws {
        let conversation = try decode(payload(status: nil, turns: """
        [{"index": 0, "role": "user", "text": "안녕"}]
        """))
        XCTAssertEqual(conversation.status, .ok)
    }
}

/// A fetch that fails has to leave something behind. Storing only the
/// success left the row spinning on "대화를 읽는 중…" forever, which reads
/// as a slow machine rather than as a question that was answered and lost.
final class ConversationLoadStateTests: XCTestCase {
    func test_onlyTheLoadedCaseYieldsAConversation() throws {
        let conversation = try JSONDecoder().decode(SessionConversation.self, from: Data("""
        {"status": "ok", "provider": "claude", "sessionId": "s", "workspace": null,
         "messageCount": 0, "userTurnCount": 0, "firstUserTurn": null,
         "turns": [], "omittedTurns": 0, "masked": true}
        """.utf8))
        XCTAssertNotNil(ConversationLoadState.loaded(conversation).conversation)
        XCTAssertNil(ConversationLoadState.loading.conversation)
        XCTAssertNil(ConversationLoadState.failed("nope").conversation)
    }
}

/// The conversation cache is keyed by the bytes, not the path. A live
/// agent appends to its transcript while the screen is open, so a
/// path-keyed entry goes stale invisibly -- the path still resolves.
final class ConversationCacheKeyTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ConversationKey-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func test_appendingToATranscriptChangesItsKey() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "s.jsonl")
        try Data("{\"a\":1}\n".utf8).write(to: source)

        let before = ScanModel.conversationKey(provider: .claude, sessionID: "s", source: source)
        try Data("{\"a\":1}\n{\"b\":2}\n".utf8).write(to: source)
        let after = ScanModel.conversationKey(provider: .claude, sessionID: "s", source: source)

        XCTAssertNotEqual(before, after,
                          "a session that kept going must be a cache miss, not a stale panel")
    }

    func test_anUnchangedTranscriptKeepsItsKey() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "s.jsonl")
        try Data("{\"a\":1}\n".utf8).write(to: source)

        XCTAssertEqual(
            ScanModel.conversationKey(provider: .claude, sessionID: "s", source: source),
            ScanModel.conversationKey(provider: .claude, sessionID: "s", source: source)
        )
    }

    /// A file that cannot be stat'd still has to produce a key, so the
    /// fetch runs and `inspect` gets to report on it -- rather than being
    /// skipped here on a nil.
    func test_anUnstattableSourceStillYieldsAKey() {
        let missing = URL(fileURLWithPath: "/nope/\(UUID().uuidString).jsonl")
        let key = ScanModel.conversationKey(provider: .claude, sessionID: "s", source: missing)
        XCTAssertFalse(key.isEmpty)
    }

    /// Two stores that number their sessions alike must not share a key.
    func test_providersDoNotShareAKey() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "s.jsonl")
        try Data("x".utf8).write(to: source)
        XCTAssertNotEqual(
            ScanModel.conversationKey(provider: .claude, sessionID: "s", source: source),
            ScanModel.conversationKey(provider: .codex, sessionID: "s", source: source)
        )
    }
}

/// Editors keep per-workspace state, not a transcript. Offering "대화 보기"
/// on a VS Code `workspace.json` opens an empty panel and teaches the
/// reader that the button lies.
final class EditorStateHasNoConversationTests: XCTestCase {
    func test_onlyAgentProvidersOfferAConversation() {
        for provider in [SessionProvider.claude, .claudeDesktop, .codex, .gemini] {
            XCTAssertTrue(provider.keepsTranscripts, "\(provider) holds a transcript")
        }
        for provider in [SessionProvider.vscode, .cursor, .windsurf, .kiro, .antigravity] {
            XCTAssertFalse(provider.keepsTranscripts, "\(provider) holds editor state, not a conversation")
        }
    }

    func test_theBrowserRowFollowsTheSameRule() {
        XCTAssertTrue(SessionInspectionFixtures.entry(tool: "Claude").isReadable)
        XCTAssertTrue(SessionInspectionFixtures.entry(tool: "Claude Desktop").isReadable)
        XCTAssertEqual(SessionInspectionFixtures.entry(tool: "Claude Desktop").provider, .claudeDesktop)
        XCTAssertFalse(SessionInspectionFixtures.entry(tool: "VS Code").isReadable)
        XCTAssertFalse(SessionInspectionFixtures.entry(tool: "Kiro").isReadable)
    }

    func test_originalBackupMatchesThePythonProviderContract() {
        for tool in ["Claude", "Claude Desktop", "Codex"] {
            XCTAssertTrue(SessionInspectionFixtures.entry(tool: tool).supportsOriginalBackup)
        }
        for tool in ["Gemini", "VS Code", "Kiro"] {
            XCTAssertFalse(SessionInspectionFixtures.entry(tool: tool).supportsOriginalBackup)
        }
    }

    func test_desktopMetadataHandleOffersMaskedConversationExport() {
        let desktop = SessionInspectionFixtures.entry(
            tool: "Claude Desktop",
            source: "/Users/example/Library/Application Support/Claude/local-agent-mode-sessions/a/b/local_one.json"
        )
        XCTAssertTrue(desktop.supportsConversationExport)
        XCTAssertFalse(SessionInspectionFixtures.entry(
            tool: "Gemini",
            source: "/Users/example/.gemini/tmp/project/chats/session.json"
        ).supportsConversationExport)
    }

    /// The store's own kind wins over the provider name, so a store scree
    /// classifies one way and this app names another cannot drift into
    /// offering a conversation that is not there.
    func test_theStoreKindDecidesRatherThanTheProviderName() {
        XCTAssertFalse(SessionInspectionFixtures
            .entry(tool: "Claude", kind: "workspace_state").isReadable)
    }

    /// Editor state is listed -- it is durable local state too -- but the
    /// row has to say which it is.
    func test_theRowNamesWhatItIs() {
        XCTAssertTrue(SessionInspectionFixtures.entry(tool: "Claude").subtitle.contains("대화"))
        XCTAssertTrue(SessionInspectionFixtures.entry(tool: "VS Code").subtitle.contains("편집기 상태"))
    }
}

enum SessionInspectionFixtures {
    static func entry(
        tool: String = "Claude",
        workspace: String = "/Users/example/IdeaProjects/Modore",
        workspaceExists: Bool? = true,
        source: String? = nil,
        kind: String? = nil,
        lastActive: String = "2026-08-20 10:00"
    ) -> SessionIndexEntry {
        var json: [String: Any] = [
            "tool": tool,
            "kind": kind ?? (tool == "VS Code" || tool == "Kiro" ? "workspace_state" : "session"),
            "source": source ?? "/Users/example/.claude/projects/x/\(UUID().uuidString).jsonl",
            "workspace": workspace,
            "sizeBytes": 2048,
            "lastActive": lastActive,
        ]
        json["workspaceExists"] = workspaceExists ?? NSNull()
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(SessionIndexEntry.self, from: data)
    }
}

/// The screen opens with verdicts, which answer "what should I act on".
/// They do not answer "where is the conversation I had last Tuesday" --
/// the question that brought most people here, and the one the page had no
/// way to ask.
final class WorkSearchTests: XCTestCase {
    private func project(
        _ name: String, tool: String = "Claude", sources: [String] = []
    ) -> WorkProject {
        let path = "/Users/example/IdeaProjects/\(name)"
        return WorkProject(
            path: path,
            sessions: sources.map {
                SessionInspectionFixtures.entry(tool: tool, workspace: path, source: $0)
            }
        )
    }

    private var projects: [WorkProject] {
        [
            project("Modore", tool: "Claude",
                    sources: ["/Users/example/.claude/projects/modore/aaa.jsonl"]),
            project("AirMCP", tool: "Codex",
                    sources: ["/Users/example/.codex/sessions/bbb.jsonl"]),
        ]
    }

    func test_anEmptySearchReturnsEverything() {
        XCTAssertEqual(WorkListPane.filter(projects, search: "   ").count, 2)
    }

    func test_searchMatchesTheProjectName() {
        XCTAssertEqual(WorkListPane.filter(projects, search: "modore").map(\.name), ["Modore"])
    }

    func test_searchIgnoresCase() {
        XCTAssertEqual(WorkListPane.filter(projects, search: "AIRMCP").count, 1)
    }

    /// A search that only the conversations match still finds the project
    /// -- narrowed to the conversations that matched, so the row shows why
    /// it is in the list.
    func test_matchingOnlyAConversationNarrowsTheProject() {
        let hits = WorkListPane.filter(projects, search: "bbb.jsonl")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.sessions.count, 1)
    }

    /// Adding a word has to narrow. Typing "claude modore" should not
    /// return everything Claude ever touched.
    func test_extraTermsNarrowRatherThanWiden() {
        XCTAssertEqual(WorkListPane.filter(projects, search: "claude modore").count, 1)
        XCTAssertTrue(WorkListPane.filter(projects, search: "claude airmcp").isEmpty)
    }

    func test_theSummaryCountsWhatTheListAmountsTo() {
        let summary = WorkListPane.summary(projects)
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary!.contains("작업 2개"))
        XCTAssertNil(WorkListPane.summary([]))
    }

    /// A session with no recorded workspace still needs a name on the row.
    func test_aWorkspacelessSessionFallsBackToItsFileName() {
        let entry = SessionInspectionFixtures.entry(
            workspace: "", workspaceExists: false,
            source: "/Users/example/.claude/projects/x/orphan.jsonl")
        XCTAssertEqual(entry.displayLabel, "orphan.jsonl")
    }

    /// "Its workspace is gone" is a fact about what you would lose, so it
    /// belongs on the row -- but only when there was a workspace at all.
    func test_aVanishedWorkspaceIsSaidOutLoud() {
        XCTAssertTrue(SessionInspectionFixtures.entry(workspaceExists: false)
            .subtitle.contains("작업 경로 소멸"))
        XCTAssertFalse(SessionInspectionFixtures.entry(workspaceExists: true)
            .subtitle.contains("작업 경로 소멸"))
        XCTAssertFalse(SessionInspectionFixtures.entry(workspace: "", workspaceExists: false)
            .subtitle.contains("작업 경로 소멸"))
    }

    func test_anUnreachableWorkspaceIsNotMisreportedAsDeleted() {
        let entry = SessionInspectionFixtures.entry(workspaceExists: nil)

        XCTAssertTrue(entry.subtitle.contains("작업 경로 확인 못함"))
        XCTAssertFalse(entry.subtitle.contains("작업 경로 소멸"))
    }
}

/// Coverage is part of a search answer, not a footnote.
final class SessionSearchResultTests: XCTestCase {
    private func result(
        matches: Int = 0, scanned: Int = 100, total: Int = 100,
        unreadable: Int = 0, coverage: String = "complete", reason: String? = nil
    ) throws -> SessionSearchResult {
        let rows = (0..<matches).map { i in
            """
            {"source":"/Users/example/.claude/projects/x/\(i).jsonl","tool":"Claude",
             "workspace":"/Users/example/repo","lastActive":"2026-08-20 10:00",
             "index":\(i),"role":"user","isUser":true,"snippet":"npm cache clean"}
            """
        }.joined(separator: ",")
        let definitive = coverage == "complete" && reason == nil && unreadable == 0
        let json = """
        {"query":"npm","matches":[\(rows)],"scannedSessions":\(scanned),
         "totalSessions":\(total),"unreadableSessions":\(unreadable),
         "coverage":"\(coverage)","truncatedReason":\(reason.map { "\"\($0)\"" } ?? "null"),
         "definitive":\(definitive),"evidenceKind":"conversation_mention"}
        """
        return try JSONDecoder().decode(SessionSearchResult.self, from: Data(json.utf8))
    }

    func test_aCompleteSearchWithNothingHiddenSaysNothingExtra() throws {
        XCTAssertNil(try result().caveat)
        XCTAssertTrue(try result().isComplete)
    }

    /// A search that stopped at a time budget and reported nothing found
    /// would be a lie by omission.
    func test_aTruncatedSearchAdmitsHowFarItGot() throws {
        let r = try result(scanned: 600, total: 7210, coverage: "truncated", reason: "time")
        XCTAssertFalse(r.isComplete)
        let caveat = try XCTUnwrap(r.caveat)
        XCTAssertTrue(caveat.contains("600"))
        XCTAssertTrue(caveat.contains("7210"))
    }

    func test_aCappedSearchSaysToNarrowRatherThanClaimingCompleteness() throws {
        let caveat = try XCTUnwrap(
            try result(coverage: "truncated", reason: "limit").caveat)
        XCTAssertTrue(caveat.contains("좁히"))
    }

    func test_aDiscoveryFailureNamesTheStoreInsteadOfBlamingTheQuery() throws {
        let caveat = try XCTUnwrap(
            try result(coverage: "truncated", reason: "discovery").caveat)
        XCTAssertTrue(caveat.contains("저장소"))
        XCTAssertFalse(caveat.contains("좁히"))
    }

    /// Sessions that could not be opened are counted even when the sweep
    /// itself finished.
    func test_unreadableSessionsAreAlwaysDisclosed() throws {
        let caveat = try XCTUnwrap(try result(unreadable: 29).caveat)
        XCTAssertTrue(caveat.contains("29"))
    }

    func test_aMatchNamesTheProjectAndFallsBackToTheFileName() throws {
        let match = try XCTUnwrap(try result(matches: 1).matches.first)
        XCTAssertEqual(match.displayLabel, "repo")
        XCTAssertTrue(match.subtitle.contains("Claude"))
        XCTAssertTrue(match.subtitle.contains("나"))
    }
}


/// The exact place `unknown` turns into `none`.
final class SearchNoMatchHonestyTests: XCTestCase {
    private func result(
        unreadable: Int, coverage: String, reason: String?, total: Int = 7210
    ) throws -> SessionSearchResult {
        let definitive = coverage == "complete" && reason == nil && unreadable == 0
        let json = """
        {"query":"용량","matches":[],"scannedSessions":\(total),
         "totalSessions":\(total),"unreadableSessions":\(unreadable),
         "coverage":"\(coverage)","truncatedReason":\(reason.map { "\"\($0)\"" } ?? "null"),
         "definitive":\(definitive),"evidenceKind":"conversation_mention"}
        """
        return try JSONDecoder().decode(SessionSearchResult.self, from: Data(json.utf8))
    }

    /// A sweep that visited every session but could not open 59 of them
    /// finished -- and is still not grounds for telling someone the
    /// phrase never appears.
    func test_unreadableSessionsForbidTheFlatNoMatchSentence() throws {
        let r = try result(unreadable: 59, coverage: "complete", reason: nil)
        XCTAssertTrue(r.isComplete, "the sweep did finish")
        XCTAssertFalse(r.definitive, "but it may not conclude")
        XCTAssertFalse(r.emptyResultText.contains("없습니다"))
        XCTAssertTrue(r.emptyResultText.contains("7151"))
        XCTAssertTrue(r.emptyResultText.contains("59"))
    }

    func test_onlyAFullyReadSweepMaySayThereIsNone() throws {
        let r = try result(unreadable: 0, coverage: "complete", reason: nil)
        XCTAssertTrue(r.definitive)
        XCTAssertEqual(r.emptyResultText, "이 검색어가 나오는 대화가 없습니다.")
    }

    func test_aTruncatedSweepNeverConcludes() throws {
        for reason in ["time", "limit"] {
            let r = try result(unreadable: 0, coverage: "truncated", reason: reason)
            XCTAssertFalse(r.definitive)
            XCTAssertFalse(r.emptyResultText.contains("없습니다"))
        }
    }

    /// A hit means somebody said it, not that it was ever run.
    func test_searchDeclaresItsEvidenceKind() throws {
        XCTAssertEqual(
            try result(unreadable: 0, coverage: "complete", reason: nil).evidenceKind,
            "conversation_mention")
    }
}
