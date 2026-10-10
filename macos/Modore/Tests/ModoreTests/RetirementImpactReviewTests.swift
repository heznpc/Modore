import XCTest
@testable import Modore

final class SessionImpactOutcomeTests: XCTestCase {
    private func report(coverage: String, version: Int = 1, assessed: Bool = true) -> Data {
        Data("""
        {"schemaVersion":\(version),"workspace":"/tmp/repo","assessed":\(assessed),"coverage":"\(coverage)","bindings":[]}
        """.utf8)
    }

    func testEmptyPartialReportRemainsPartialWithoutClaimingNoSessions() {
        let outcome = ScreeService.impactOutcome(from: report(coverage: "truncated"))
        XCTAssertEqual(outcome.coverage, .partial)
        XCTAssertEqual(outcome.sessionCount, 0)
        XCTAssertNotNil(outcome.diagnostic)
        guard case .notAssessed = outcome.assessment else {
            return XCTFail("Incomplete evidence must not become an archive assessment")
        }
    }

    func testCompleteEmptyReportAndUnknownOutputAreDistinct() {
        XCTAssertEqual(ScreeService.impactOutcome(from: report(coverage: "complete")).coverage, .complete)
        XCTAssertEqual(ScreeService.impactOutcome(from: report(coverage: "complete", version: 2)).coverage, .unknown)
        XCTAssertEqual(ScreeService.impactOutcome(from: report(coverage: "complete", assessed: false)).coverage, .unknown)
        XCTAssertEqual(ScreeService.impactOutcome(from: report(coverage: "future")).coverage, .unknown)
        XCTAssertEqual(ScreeService.impactOutcome(from: Data()).coverage, .unknown)
    }

    func testSelectedPreviewTargetsDoNotDependOnTheWorkIndex() throws {
        let data = Data("""
        {"id":"outside-work-index","path":"/tmp/new-repo","remote":null,"archive":false,"local":true,
        "deleteGenerated":false,"warnings":[],"approved":false,"changed":false,"error":"",
        "archiveMutation":"pending","archiveVerification":"pending","localMutation":"pending",
        "localVerification":"pending","deleteBytes":0,"keepBytes":0,"generatedBytes":0,"deletedCount":0,"files":[]}
        """.utf8)
        let item = try JSONDecoder().decode(AssetRetirementItem.self, from: data)
        let targets = SessionImpactTarget.selected(from: [item, item], ids: [item.id])
        XCTAssertEqual(targets, [.init(workspace: URL(fileURLWithPath: "/tmp/new-repo"), repoURL: nil)])
        XCTAssertTrue(SessionImpactTarget.selected(from: [item], ids: []).isEmpty)
    }
}

@MainActor
final class RetirementImpactReviewTests: XCTestCase {
    func testCancelPropagatesToTrackedWorkAndRejectsItsResult() async {
        let owner = ScanModel(automaticallyScansStaleResults: false)
        let review = RetirementImpactReview()
        let target = SessionImpactTarget(workspace: URL(fileURLWithPath: "/tmp/repo"), repoURL: nil)
        var entered = false
        var cancelled = false
        review.start(targets: [target], owner: owner, using: { _ in
            entered = true
            do { try await Task.sleep(nanoseconds: 10_000_000_000) }
            catch { cancelled = Task.isCancelled }
            return [target.workspace.path: .init(assessment: .assessedNoSessions, diagnostic: nil)]
        })
        while !entered { await Task.yield() }
        review.cancel()
        for _ in 0..<100 where !cancelled { await Task.yield() }
        XCTAssertTrue(cancelled)
        XCTAssertFalse(review.isLoading)
        XCTAssertEqual(review.outcomes[target.workspace.path]?.coverage, .unknown)
        XCTAssertNil(review.observedAt)
    }

    func testRepositoryMetadataInspectionFinishesWithoutDeepBinding() async {
        let owner = ScanModel(automaticallyScansStaleResults: false)
        owner.refreshArchiveCandidates(using: {
            RepoScanOutcome(candidates: [], failures: [:], notScanned: [])
        })
        for _ in 0..<100 where owner.archiveLoading { await Task.yield() }
        XCTAssertTrue(owner.archiveInspectionComplete)
        XCTAssertFalse(owner.archiveLoading)
        XCTAssertNil(owner.archiveTask)
    }
}
