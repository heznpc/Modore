import Foundation
import XCTest
@testable import Modore

@MainActor
final class ConversationSnapshotTests: XCTestCase {
    func testAppendDuringReadKeepsResultVisibleAndExplicitRefreshSelectsNewVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("session.jsonl")
        try Data("first\n".utf8).write(to: source)
        let model = ScanModel(automaticallyScansStaleResults: false, projectRoot: root)
        let key = model.selectConversationSnapshot(source: source, provider: .codex)
        let token = UUID()
        model.conversationLoadTokens[key] = token
        model.conversationLoads[key] = .loading
        let writer = try FileHandle(forWritingTo: source)
        try writer.seekToEnd(); try writer.write(contentsOf: Data("second\n".utf8)); try writer.close()
        if case .loading = model.conversationState(source: source, provider: .codex) {} else {
            XCTFail("Appending during a read must not lose its loading state")
        }
        let conversation = try JSONDecoder().decode(SessionConversation.self, from: Data("""
        {"status":"ok","provider":"codex","sessionId":"s","workspace":null,
         "messageCount":1,"userTurnCount":1,"firstUserTurn":"first",
         "turns":[{"index":0,"role":"user","text":"first"}],"omittedTurns":0,"masked":true}
        """.utf8))
        XCTAssertTrue(model.finishConversationLoad(key: key, token: token, state: .loaded(conversation)))
        XCTAssertEqual(model.conversationState(source: source, provider: .codex)?.conversation?.turns.first?.text, "first")
        XCTAssertTrue(model.conversationSnapshotNeedsRefresh(source: source, provider: .codex))
        XCTAssertNil(model.conversationState(source: source, provider: .claude))
        let newer = model.selectConversationSnapshot(source: source, provider: .codex)
        XCTAssertNotEqual(key, newer)
        XCTAssertFalse(model.conversationSnapshotNeedsRefresh(source: source, provider: .codex))
        XCTAssertNil(model.conversationState(source: source, provider: .codex))
        XCTAssertFalse(model.finishConversationLoad(key: key, token: token, state: .loaded(conversation)))
    }
}
