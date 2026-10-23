import XCTest
@testable import Modore

private actor SearchResultGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var entered = false

    func wait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class ContentSearchLifecycleTests: XCTestCase {
    func testSearchHitUsesItsOwnWindowAndDoesNotReuseTheRecentTail() async throws {
        let model = ScanModel(automaticallyScansStaleResults: false)
        let match = try XCTUnwrap(result(indices: [4], offset: 0, nextOffset: nil).matches.first)
        let tail = try conversation(start: 80)
        let tailKey = ScanModel.conversationKey(provider: match.provider, sessionID: match.source, source: match.sourceURL)
        model.conversationLoads[tailKey] = .loaded(tail)
        let selectedWindow = try conversation(start: 4)
        var inspectedStarts: [Int?] = []
        let inspect: ([URL], Int?) async -> Result<SessionConversation, ScreeInspectionError> = { sources, start in
            XCTAssertEqual(sources, [match.sourceURL])
            inspectedStarts.append(start)
            return .success(selectedWindow)
        }
        model.openSearchMatch(match, using: inspect)
        for task in model.trackedApplicationTasks.values.map(\.task) { await task.value }
        XCTAssertEqual(inspectedStarts, [4])
        XCTAssertEqual(model.selectedSearchMatchForDetail, match)
        XCTAssertEqual(model.conversationState(source: match.sourceURL, provider: match.provider, start: 4)?.conversation?.windowStart, 4)
        XCTAssertEqual(model.conversationState(source: match.sourceURL, provider: match.provider)?.conversation?.windowStart, 80)

        model.openSearchMatch(match, using: inspect)
        XCTAssertEqual(inspectedStarts, [4], "reopening the same hit should reuse only its own window")
        model.openSearchMatch(match, retry: true, using: inspect)
        for task in model.trackedApplicationTasks.values.map(\.task) { await task.value }
        XCTAssertEqual(inspectedStarts, [4, 4], "retry must preserve the selected hit ordinal")
        XCTAssertNotEqual(tailKey, ScanModel.conversationKey(provider: match.provider, sessionID: match.source, source: match.sourceURL, start: 4))
        XCTAssertNotEqual(ScanModel.conversationKey(provider: match.provider, sessionID: match.source, source: match.sourceURL, start: 4), ScanModel.conversationKey(provider: match.provider, sessionID: match.source, source: match.sourceURL, start: 9))
        model.cancelWorkScreenTasks()
    }

    private func conversation(start: Int) throws -> SessionConversation {
        let json: [String: Any] = [
            "status": "ok", "provider": "claude", "sessionId": "fixture", "workspace": NSNull(),
            "messageCount": 100, "userTurnCount": 100, "firstUserTurn": "first",
            "windowStart": start, "turns": [["index": 0, "sourceIndex": start, "role": "user", "text": "turn \(start)"]],
            "omittedTurns": 99, "masked": true,
        ]
        return try JSONDecoder().decode(SessionConversation.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testNextPageAndRetryKeepSubmittedScopeAfterFieldsChange() async throws {
        let model = ScanModel(automaticallyScansStaleResults: false)
        let request = SessionSearchRequest(query: "needle", provider: "claude", workspace: "archive", offset: 0, limit: 2)
        let first = try result(indices: [0, 1], offset: 0, nextOffset: 2)
        model.performContentSearch(request, using: { _ in .success(first) })
        await model.contentSearchTask?.value

        model.sessionSearch = "different draft"
        model.contentSearchProvider = "codex"
        model.contentSearchWorkspace = "another project"
        var failedRequest: SessionSearchRequest?
        model.loadMoreContentSearch(using: { request in
            failedRequest = request
            return .failure(.init(message: "temporary read error"))
        })
        await model.contentSearchTask?.value
        XCTAssertEqual(failedRequest, request.page(at: 2))
        XCTAssertEqual(model.contentSearch?.matches.count, 2)
        XCTAssertEqual(model.contentSearchError, "temporary read error")

        let second = try result(indices: [1, 2, 3], offset: 2, nextOffset: nil)
        var retriedRequest: SessionSearchRequest?
        model.retryContentSearch(using: { request in
            retriedRequest = request
            return .success(second)
        })
        await model.contentSearchTask?.value
        XCTAssertEqual(retriedRequest, failedRequest)
        XCTAssertEqual(model.contentSearch?.matches.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(model.contentSearch?.hasMore, false)
        XCTAssertNil(model.contentSearchError)
        XCTAssertNil(model.contentSearchTask)
        model.cancelWorkScreenTasks()
    }

    func testClearingInFlightSearchCannotRestoreItsLateResult() async throws {
        let model = ScanModel(automaticallyScansStaleResults: false)
        let request = SessionSearchRequest(query: "needle", provider: "claude", workspace: "archive", offset: 0, limit: 2)
        let lateResult = try result(indices: [0], offset: 0, nextOffset: nil)
        let gate = SearchResultGate()
        model.performContentSearch(request, using: { _ in
            await gate.wait()
            return .success(lateResult)
        })
        let oldTask = model.contentSearchTask
        model.clearContentSearch()
        XCTAssertFalse(model.contentSearchRunning)
        XCTAssertTrue(oldTask?.isCancelled == true)
        await gate.release()
        await oldTask?.value
        XCTAssertNil(model.contentSearch)
        XCTAssertNil(model.contentSearchError)
        XCTAssertNil(model.contentSearchRequest)
        model.cancelWorkScreenTasks()
    }

    func testCancelledOlderSearchDoesNotStopOrReplaceNewSearch() async throws {
        let model = ScanModel(automaticallyScansStaleResults: false)
        let request = SessionSearchRequest(query: "needle", provider: "claude", workspace: "archive", offset: 0, limit: 2)
        let oldResult = try result(indices: [0], offset: 0, nextOffset: nil)
        let newResult = try result(indices: [9], offset: 0, nextOffset: nil)
        let gate = SearchResultGate()
        model.performContentSearch(request, using: { _ in
            await gate.wait()
            return .success(oldResult)
        })
        let oldTask = model.contentSearchTask
        model.performContentSearch(request, using: { _ in .success(newResult) })
        await model.contentSearchTask?.value
        await gate.release()
        await oldTask?.value
        XCTAssertEqual(model.contentSearch?.matches.map(\.index), [9])
        XCTAssertFalse(model.contentSearchRunning)
        XCTAssertNil(model.contentSearchTask)
        model.cancelWorkScreenTasks()
    }

    func testUnknownRemainderCannotEnableNextPage() async throws {
        let model = ScanModel(automaticallyScansStaleResults: false)
        let request = SessionSearchRequest(query: "needle", provider: "claude", workspace: "archive", offset: 0, limit: 2)
        let timedOut = try result(indices: [0], offset: 0, nextOffset: nil, reason: "time")
        model.performContentSearch(request, using: { _ in .success(timedOut) })
        await model.contentSearchTask?.value
        var invoked = false
        model.loadMoreContentSearch(using: { _ in
            invoked = true
            return .success(timedOut)
        })
        XCTAssertFalse(invoked)
        XCTAssertNil(model.contentSearchTask)
        XCTAssertNil(model.contentSearch?.hasMore)
        XCTAssertFalse(model.contentSearch?.definitive ?? true)
        model.cancelWorkScreenTasks()
    }

    private func result(indices: [Int], offset: Int, nextOffset: Int?, reason: String? = nil) throws -> SessionSearchResult {
        let matches: [[String: Any]] = indices.map { index in
            ["source": "/example/session.jsonl", "tool": "Claude", "workspace": "/example/archive",
             "lastActive": "2026-10-01 10:00", "index": index, "role": "user", "isUser": true,
             "snippet": "needle \(index)"]
        }
        let complete = nextOffset == nil && reason == nil
        let json: [String: Any] = [
            "query": "needle", "matches": matches,
            "scannedSessions": 1, "totalSessions": 1, "unreadableSessions": 0,
            "coverage": complete ? "complete" : "truncated",
            "truncatedReason": reason ?? (complete ? NSNull() : "limit" as Any),
            "definitive": complete, "evidenceKind": "conversation_mention",
            "offset": offset, "nextOffset": nextOffset as Any? ?? NSNull(),
            "hasMore": reason == nil ? (nextOffset != nil) : NSNull(),
            "scope": ["provider": "claude", "workspace": "archive"],
        ]
        return try JSONDecoder().decode(SessionSearchResult.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
