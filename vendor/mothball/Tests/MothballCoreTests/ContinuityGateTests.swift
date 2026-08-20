import XCTest
@testable import MothballCore

/// The gate is the whole policy, so the policy is tested as a table.
///
/// The case that matters most is the pair `notAssessed` / `assessedNoSessions`.
/// Any refactor that collapses them — an `Optional<[SessionBinding]>`, an
/// `isEmpty` check, a count — passes every other test in this file and
/// reintroduces the exact hazard: a caller that never ran a binder is
/// treated like one that ran it and found nothing, and a workspace is
/// trashed while its transcripts are still only referenced by a path
/// that is about to stop existing.
final class ContinuityGateTests: XCTestCase {

    func test_notAssessed_blocks() {
        XCTAssertEqual(ContinuityGate.evaluate(.notAssessed), .block(.notAssessed))
    }

    func test_assessedNoSessions_allows() {
        XCTAssertEqual(ContinuityGate.evaluate(.assessedNoSessions), .allow)
    }

    func test_notAssessedAndAssessedNoSessions_disagree() {
        // The one assertion this file exists for.
        XCTAssertNotEqual(
            ContinuityGate.evaluate(.notAssessed),
            ContinuityGate.evaluate(.assessedNoSessions)
        )
    }

    func test_unsealedBindings_block() {
        let binding = SessionBinding(
            provider: .claude,
            sessionID: "abc",
            source: URL(fileURLWithPath: "/tmp/abc.jsonl"),
            evidence: [.workingDirectory],
            confidence: .medium
        )
        XCTAssertEqual(
            ContinuityGate.evaluate(.bindings([binding], coverage: .complete)),
            .block(.unsealedSessions(count: 1))
        )
    }

    /// A binder that found nothing must say `assessedNoSessions`. If it
    /// returns `bindings([])` instead, that is a bug in the binder, and
    /// the gate refuses rather than letting the degenerate array read as
    /// a pass — which would quietly restore the collapsed distinction.
    func test_emptyBindings_blockRatherThanPass() {
        XCTAssertEqual(
            ContinuityGate.evaluate(.bindings([], coverage: .complete)),
            .block(.unsealedSessions(count: 0))
        )
    }

    func test_sealed_allows() {
        let bundle = ContinuityBundle(
            stagingRoot: URL(fileURLWithPath: "/tmp/staging"),
            sessions: [
                SealedSession(
                    provider: .codex, sessionID: "s1", artifact: "sessions/codex/s1",
                    sha256: "deadbeef", sizeBytes: 10, fileCount: 1,
                    evidence: [.remoteURL], confidence: .high
                )
            ]
        )
        XCTAssertEqual(ContinuityGate.evaluate(.sealed(bundle, coverage: .complete)), .allow)
    }

    func test_userOverride_allows() {
        XCTAssertEqual(
            ContinuityGate.evaluate(.overriddenByUser(reason: "no binder")),
            .allow
        )
    }

    func test_manifestTags_areDistinctPerState() {
        let tags = [
            ContinuityAssessment.notAssessed.manifestTag,
            ContinuityAssessment.assessedNoSessions.manifestTag,
            ContinuityAssessment.bindings([], coverage: .complete).manifestTag,
            ContinuityAssessment.sealed(.init(stagingRoot: URL(fileURLWithPath: "/tmp"), sessions: []), coverage: .complete).manifestTag,
            ContinuityAssessment.overriddenByUser(reason: "x").manifestTag,
        ]
        XCTAssertEqual(Set(tags).count, tags.count, "each state must be distinguishable on disk")
    }
}

/// "Found a session" and "found every session" are different facts, and
/// the model used to keep the difference only when the list was empty --
/// which is exactly where it costs least. A partial scan that turns up
/// one session and seals it perfectly has preserved that one and
/// abandoned the ones it never looked for, while reporting success.
final class CoverageGateTests: XCTestCase {

    private func bundle(_ count: Int = 1) -> ContinuityBundle {
        ContinuityBundle(
            stagingRoot: URL(fileURLWithPath: "/tmp/staging"),
            sessions: (0..<count).map { i in
                SealedSession(
                    provider: .codex, sessionID: "s\(i)",
                    artifact: "sessions/codex/s\(i)", sha256: "abc",
                    sizeBytes: 10, fileCount: 1,
                    evidence: [.remoteURL], confidence: .high
                )
            }
        )
    }

    /// The case the review named: a shallow pass found one session, that
    /// session was sealed, and a store nobody read is still out there.
    func test_sealedFromAShallowScanStillBlocks() {
        XCTAssertEqual(
            ContinuityGate.evaluate(.sealed(bundle(), coverage: .shallow)),
            .block(.incompleteCoverage(.shallow))
        )
    }

    func test_sealedFromATruncatedScanStillBlocks() {
        XCTAssertEqual(
            ContinuityGate.evaluate(.sealed(bundle(), coverage: .truncated)),
            .block(.incompleteCoverage(.truncated))
        )
    }

    func test_sealedFromACompleteScanIsAllowed() {
        XCTAssertEqual(ContinuityGate.evaluate(.sealed(bundle(), coverage: .complete)), .allow)
    }

    /// Sealing is necessary and not sufficient: perfect sealing of a
    /// partial finding must not read the same as a finished job.
    func test_sealingDoesNotSubstituteForLooking() {
        XCTAssertNotEqual(
            ContinuityGate.evaluate(.sealed(bundle(3), coverage: .shallow)),
            ContinuityGate.evaluate(.sealed(bundle(3), coverage: .complete))
        )
    }

    /// Unsealed bindings block regardless of coverage — there is nothing
    /// to weigh yet.
    func test_unsealedBindingsBlockAtEveryCoverage() {
        for coverage in [BindingCoverage.shallow, .truncated, .complete] {
            let binding = SessionBinding(
                provider: .claude, sessionID: "a",
                source: URL(fileURLWithPath: "/s/a.jsonl"),
                evidence: [.workingDirectory], confidence: .medium
            )
            XCTAssertEqual(
                ContinuityGate.evaluate(.bindings([binding], coverage: coverage)),
                .block(.unsealedSessions(count: 1))
            )
        }
    }

    /// `assessedNoSessions` is only reachable from a complete pass, so it
    /// reports the coverage it required rather than leaving it nil.
    func test_assessedNoSessionsReportsCompleteCoverage() {
        XCTAssertEqual(ContinuityAssessment.assessedNoSessions.coverage, .complete)
        XCTAssertNil(ContinuityAssessment.notAssessed.coverage)
    }

    func test_refusalMessagesNameTheDifferentProblems() {
        let incomplete = ContinuityGate.Refusal.incompleteCoverage(.shallow).message
        let unsealed = ContinuityGate.Refusal.unsealedSessions(count: 2).message
        XCTAssertNotEqual(incomplete, unsealed)
        XCTAssertTrue(incomplete.contains("완전하지 않"), incomplete)
    }
}
