import XCTest
@testable import MothballCore

/// The process boundary is where the `notAssessed` / `assessedNoSessions`
/// distinction is easiest to lose, because on the wire both are just an
/// empty array. These tests pin that it survives the crossing.
final class BindReportTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    func test_assessedWithNoBindings_isAssessedNoSessions() {
        let json = """
        {"workspace":"/w","repoUrl":null,"assessed":true,"deep":false,"bindings":[]}
        """
        guard case .assessedNoSessions = ContinuityAssessment.fromBindReport(data(json)) else {
            return XCTFail("a completed binder run that found nothing must say so")
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
        guard case .bindings(let bindings) = ContinuityAssessment.fromBindReport(data(json)) else {
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
         "bindings":[{"provider":"gemini","sessionId":"g1","source":"/s/g1.jsonl",
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
        {"workspace":"/w","repoUrl":null,"assessed":true,"deep":false,"bindings":[]}
        """
        let found = """
        {"workspace":"/w","repoUrl":null,"assessed":true,"deep":false,
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
}
