import XCTest
@testable import ModoreDomain

final class EvidenceTests: XCTestCase {
    private struct Observation: EvidenceBackedRecord, Equatable {
        let evidence: EvidenceRecord
    }
    private let coverage = Coverage(state: .unknown, scope: "Display description")

    private func record(run: String = "run", id: String = "record") throws -> Observation {
        Observation(evidence: try EvidenceRecord(
            reference: EvidenceReference(source: .scree, runID: run, recordID: id),
            method: .recordedWorkspace, basis: .recordedClaim, observedAt: nil, coverage: coverage))
    }

    func testInvalidIdentitiesAreRejectedByConstructionAndDecoding() throws {
        XCTAssertThrowsError(try ProjectIdentity(comparisonKey: ""))
        XCTAssertThrowsError(try AssetIdentity(namespace: "", key: "path"))
        XCTAssertThrowsError(try AssetIdentity(namespace: "path", key: ""))
        XCTAssertThrowsError(try EvidenceReference(source: .scree, runID: "", recordID: "r"))
        XCTAssertThrowsError(try EvidenceReference(source: .scree, runID: "r", recordID: ""))
        XCTAssertThrowsError(try JSONDecoder().decode(ProjectIdentity.self, from: Data(#"{"comparisonKey":""}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(AssetIdentity.self, from: Data(#"{"namespace":"path","key":""}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(EvidenceReference.self, from: Data(#"{"source":"scree","runID":"r","recordID":""}"#.utf8)))
        let project = try ProjectIdentity(comparisonKey: "/Repo/")
        XCTAssertEqual(project.comparisonKey, "/Repo/", "Domain must not normalize or inspect OS paths")
        XCTAssertEqual(try JSONDecoder().decode(ProjectIdentity.self, from: JSONEncoder().encode(project)), project)
    }

    func testRecordedInvocationCannotBecomeObservedSuccessfulAccess() throws {
        let reference = try EvidenceReference(source: .fileAccess, runID: "run", recordID: "read")
        for method in [EvidenceMethod.transcriptReadInvocation, .transcriptWriteInvocation, .transcriptShellReference] {
            XCTAssertThrowsError(try EvidenceRecord(reference: reference, method: method,
                                                   basis: .observed, observedAt: nil, coverage: coverage))
        }
        let claim = try EvidenceRecord(reference: reference, method: .transcriptReadInvocation,
                                       basis: .recordedClaim, observedAt: nil, coverage: coverage)
        let encoded = try JSONEncoder().encode(claim)
        XCTAssertEqual(try JSONDecoder().decode(EvidenceRecord.self, from: encoded), claim)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for invalid in ["observed", "failed", "unknown", "notCollected"] {
            json["basis"] = invalid
            XCTAssertThrowsError(try JSONDecoder().decode(EvidenceRecord.self,
                from: JSONSerialization.data(withJSONObject: json)))
        }
    }

    func testFailureAndUncollectedSnapshotsCannotContainFacts() throws {
        for outcome in [CollectionOutcome.failed, .notCollected, .unknown] {
            XCTAssertThrowsError(try ProducerSnapshot(producer: .scree, runID: "run", observedAt: nil,
                outcome: outcome, coverage: coverage, records: [record()]))
            let empty = try ProducerSnapshot<Observation>(producer: .scree, runID: "run", observedAt: nil,
                outcome: outcome, coverage: coverage, records: [])
            XCTAssertTrue(empty.records.isEmpty)
        }
    }

    func testPartialSnapshotRetainsFactsAndSeparateFailures() throws {
        let snapshot = try ProducerSnapshot(producer: .scree, runID: "run", observedAt: nil,
            outcome: .partial, coverage: coverage, records: [record()],
            failures: [ProducerFailure(code: .unreadable, recordID: "other", detail: "Cannot read input")])
        XCTAssertEqual(snapshot.records.count, 1)
        XCTAssertEqual(snapshot.failures.count, 1)
        XCTAssertNil(snapshot.records[0].evidence.observedAt)
        XCTAssertEqual(try JSONDecoder().decode(ProducerSnapshot<Observation>.self,
                                               from: JSONEncoder().encode(snapshot)), snapshot)
    }

    func testSnapshotRejectsWrongRunSourceDuplicateIDsAndUnsupportedSchema() throws {
        let observation = try record()
        XCTAssertThrowsError(try ProducerSnapshot(producer: .scree, runID: "other", observedAt: nil,
            outcome: .complete, coverage: coverage, records: [observation]))
        XCTAssertThrowsError(try ProducerSnapshot(producer: .projectAttribution, runID: "run", observedAt: nil,
            outcome: .complete, coverage: coverage, records: [observation]))
        XCTAssertThrowsError(try ProducerSnapshot(producer: .scree, runID: "run", observedAt: nil,
            outcome: .complete, coverage: coverage, records: [observation, observation]))
        let snapshot = try ProducerSnapshot(producer: .scree, runID: "run", observedAt: nil,
            outcome: .complete, coverage: coverage, records: [observation])
        let encoded = try JSONEncoder().encode(snapshot)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for (key, value) in [("runID", "other" as Any), ("producer", "projectAttribution"),
                             ("outcome", "failed"), ("schemaVersion", 99)] {
            var json = original
            json[key] = value
            XCTAssertThrowsError(try JSONDecoder().decode(ProducerSnapshot<Observation>.self,
                from: JSONSerialization.data(withJSONObject: json)), key)
        }
    }
}
