import XCTest
@testable import MothballCore

/// The process boundary is where the `notAssessed` / `assessedNoSessions`
/// distinction is easiest to lose, because on the wire both are just an
/// empty array. These tests pin that it survives the crossing.
final class BindReportTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    func test_completePassWithNoBindings_isAssessedNoSessions() {
        let json = """
        {"workspace":"/w","repoUrl":null,"assessed":true,"deep":true,
         "coverage":"complete","bindings":[]}
        """
        guard case .assessedNoSessions = ContinuityAssessment.fromBindReport(data(json)) else {
            return XCTFail("a pass that could have seen everything and found nothing must say so")
        }
    }

    /// A shallow pass matches recorded working directories only. Finding
    /// nothing there means no session *ran* in this workspace, which is a
    /// weaker claim than no session touched it — a repo worked on from a
    /// parent directory records every conversation under the parent. So a
    /// shallow empty result is not evidence of absence, and treating it as
    /// one deletes exactly the workspaces whose bindings are hardest to
    /// see.
    func test_shallowPassWithNoBindings_doesNotClaimEmptiness() {
        let json = """
        {"workspace":"/w","repoUrl":null,"assessed":true,"deep":false,
         "coverage":"shallow","bindings":[]}
        """
        guard case .notAssessed = ContinuityAssessment.fromBindReport(data(json)) else {
            return XCTFail("a shallow empty result must not read as proof of absence")
        }
    }

    /// A content scan that stopped early looked deeply, not completely --
    /// a repo path can appear on the last line of a fifty-megabyte
    /// session. Treating "tried hard" as "found nothing" is the same
    /// false-completeness the shallow case already blocks.
    func test_truncatedPassWithNoBindings_doesNotClaimEmptiness() {
        let json = """
        {"workspace":"/w","repoUrl":null,"assessed":true,"deep":true,
         "coverage":"truncated","bindings":[]}
        """
        guard case .notAssessed = ContinuityAssessment.fromBindReport(data(json)) else {
            return XCTFail("a scan that stopped early must not read as proof of absence")
        }
    }

    /// An older binder with no `coverage` field cannot have been complete.
    func test_missingCoverage_isTreatedAsShallow() {
        let json = """
        {"workspace":"/w","repoUrl":null,"assessed":true,"deep":false,"bindings":[]}
        """
        guard case .notAssessed = ContinuityAssessment.fromBindReport(data(json)) else {
            return XCTFail("absent coverage must not be assumed complete")
        }
    }

    /// Same empty array, opposite meaning. If this ever returns
    /// `assessedNoSessions`, a workspace nobody checked becomes
    /// archivable.
    func test_assessedFalse_isNotAssessed() {
        let json = """
        {"workspace":"/w","repoUrl":null,"assessed":false,"deep":false,"bindings":[]}
        """
        guard case .notAssessed = ContinuityAssessment.fromBindReport(data(json)) else {
            return XCTFail("an incomplete run must not read as an empty result")
        }
    }

    func test_missingAssessedField_isNotAssessed() {
        let json = """
        {"workspace":"/w","repoUrl":null,"bindings":[]}
        """
        guard case .notAssessed = ContinuityAssessment.fromBindReport(data(json)) else {
            return XCTFail("a payload without the field cannot be trusted to mean 'empty'")
        }
    }

    func test_garbageInput_isNotAssessed() {
        guard case .notAssessed = ContinuityAssessment.fromBindReport(data("not json at all")) else {
            return XCTFail("unparseable output means nobody established anything")
        }
    }

    func test_bindingsDecodeWithEvidenceAndSubtranscripts() {
        let json = """
        {"workspace":"/w","repoUrl":"github.com/heznpc/x","assessed":true,"deep":true,
         "bindings":[
           {"provider":"codex","sessionId":"c1","source":"/s/c1.jsonl","subtranscripts":[],
            "evidence":["remote-url"],"confidence":"high","sizeBytes":10},
           {"provider":"claude","sessionId":"a1","source":"/s/a1.jsonl",
            "subtranscripts":["/s/a1/sub/one.jsonl","/s/a1/sub/two.jsonl"],
            "evidence":["working-directory"],"confidence":"medium","sizeBytes":20}
         ]}
        """
        guard case .bindings(let bindings, _) = ContinuityAssessment.fromBindReport(data(json)) else {
            return XCTFail("expected bindings")
        }
        XCTAssertEqual(bindings.count, 2)
        let claude = bindings.first { $0.provider == .claude }
        XCTAssertEqual(claude?.subtranscripts.count, 2)
        XCTAssertEqual(claude?.confidence, .medium)
        XCTAssertEqual(bindings.first { $0.provider == .codex }?.evidence, [.remoteURL])
    }

    /// A workspace with sessions must never come back looking session-free
    /// because this build did not recognise a provider or evidence type a
    /// newer binder emitted. Losing entries silently makes a workspace
    /// look safer than it is, so any loss fails the whole assessment.
    func test_unknownProvider_failsTheAssessmentRatherThanShrinkingIt() {
        let json = """
        {"workspace":"/w","repoUrl":null,"assessed":true,"deep":false,
         "bindings":[{"provider":"telepath","sessionId":"g1","source":"/s/g1.jsonl",
                      "subtranscripts":[],"evidence":["working-directory"],
                      "confidence":"medium","sizeBytes":1}]}
        """
        guard case .notAssessed = ContinuityAssessment.fromBindReport(data(json)) else {
            return XCTFail("an unreadable entry must not silently reduce the binding set")
        }
    }

    func test_unknownEvidenceType_failsTheAssessment() {
        let json = """
        {"workspace":"/w","repoUrl":null,"assessed":true,"deep":false,
         "bindings":[{"provider":"claude","sessionId":"a1","source":"/s/a1.jsonl",
                      "subtranscripts":[],"evidence":["telepathy"],
                      "confidence":"medium","sizeBytes":1}]}
        """
        guard case .notAssessed = ContinuityAssessment.fromBindReport(data(json)) else {
            return XCTFail("unknown evidence must not be dropped into a weaker-looking binding")
        }
    }

    /// End-to-end through the gate: what the binder says decides whether
    /// the archive may proceed.
    func test_gateFollowsTheDecodedAssessment() {
        let empty = """
        {"workspace":"/w","repoUrl":null,"assessed":true,"deep":true,
         "coverage":"complete","bindings":[]}
        """
        let found = """
        {"workspace":"/w","repoUrl":null,"assessed":true,"deep":false,
         "coverage":"shallow",
         "bindings":[{"provider":"claude","sessionId":"a1","source":"/s/a1.jsonl",
                      "subtranscripts":[],"evidence":["working-directory"],
                      "confidence":"medium","sizeBytes":1}]}
        """
        XCTAssertEqual(ContinuityGate.evaluate(.fromBindReport(data(empty))), .allow)
        XCTAssertEqual(
            ContinuityGate.evaluate(.fromBindReport(data(found))),
            .block(.unsealedSessions(count: 1))
        )
    }
    /// The contract's versioning rule, enforced on the consumer side: a
    /// snapshot from a future schema is unreadable, not best-effort
    /// parseable -- the fields this build recognises may no longer mean
    /// what they meant when it was written.
    func test_aFutureSchemaVersionIsUnreadableNotBestEffort() {
        let json = """
        {"schema":"modore.agent-state-snapshot","schemaVersion":2,
         "workspace":"/w","repoUrl":null,"assessed":true,"deep":true,
         "coverage":"complete","bindings":[]}
        """
        guard case .notAssessed = ContinuityAssessment.fromBindReport(data(json)) else {
            return XCTFail("a v2 snapshot must not be parsed by v1 rules")
        }
    }

    /// Pre-contract output has no schema fields and is version 1 in fact.
    func test_absentSchemaFieldsDecodeAsVersionOne() {
        let json = """
        {"workspace":"/w","repoUrl":null,"assessed":true,"deep":true,
         "coverage":"complete","bindings":[]}
        """
        guard case .assessedNoSessions = ContinuityAssessment.fromBindReport(data(json)) else {
            return XCTFail("pre-contract output must keep decoding")
        }
    }
}
