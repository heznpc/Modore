import XCTest
import ModoreDomain
@testable import Modore

final class WorkWorkspaceAdapterTests: XCTestCase {
    func testMetadataAndAttributionHaveSeparateProvenanceAndClaims() throws {
        let session = SessionInspectionFixtures.entry(workspace: "/repo/.claude/worktrees/x")
        let index = SessionIndex(total: 1, sessions: [session])
        var provenance = WorkProvenance()
        provenance.didPublish(.sessionIndex)
        let first = try WorkWorkspaceAdapter.adapt(index: index, roots: [], provenance: provenance)
        let metadata = try XCTUnwrap(first.metadata?.records.first)
        let attribution = try XCTUnwrap(first.attribution.records.first)
        XCTAssertEqual(metadata.recordedWorkspace, session.workspace)
        XCTAssertEqual(metadata.evidence.reference.source, .scree)
        XCTAssertEqual(metadata.evidence.method, .recordedWorkspace)
        XCTAssertEqual(metadata.evidence.basis, .recordedClaim)
        XCTAssertNil(metadata.evidence.observedAt)
        XCTAssertEqual(metadata.evidence.coverage.state, .unknown)
        XCTAssertEqual(attribution.workspace, metadata)
        XCTAssertEqual(attribution.project.comparisonKey, "/repo")
        XCTAssertEqual(attribution.evidence.reference.source, .projectAttribution)
        XCTAssertEqual(attribution.evidence.method, .conventionalWorktreePath)
        XCTAssertEqual(attribution.evidence.basis, .inferred)
        XCTAssertNotEqual(attribution.evidence.reference.runID, metadata.evidence.reference.runID)

        let repeated = try WorkWorkspaceAdapter.adapt(index: index, roots: [], provenance: provenance)
        XCTAssertEqual(repeated.metadata, first.metadata)
        XCTAssertEqual(repeated.attribution, first.attribution)

        // The same recorded workspace now matches a more specific established root.
        provenance.didPublish(.screeReport)
        let changed = try WorkWorkspaceAdapter.adapt(index: index, roots: [session.workspace], provenance: provenance)
        XCTAssertEqual(changed.metadata, first.metadata)
        XCTAssertEqual(changed.attribution.records.first?.project.comparisonKey, session.workspace)
        XCTAssertEqual(changed.attribution.records.first?.evidence.method, .knownRootAncestry)
        XCTAssertNotEqual(changed.attribution.runID, first.attribution.runID)
        XCTAssertEqual(attribution.project.comparisonKey, "/repo", "Previously emitted value stays immutable")

        provenance.didPublish(.sessionIndex)
        let recollected = try WorkWorkspaceAdapter.adapt(index: index, roots: [session.workspace], provenance: provenance)
        XCTAssertNotEqual(recollected.metadata?.runID, changed.metadata?.runID)
        XCTAssertNotEqual(recollected.attribution.runID, changed.attribution.runID)
    }

    func testEmptyWorkspaceAndMissingCollectionHaveNoEvidence() throws {
        var provenance = WorkProvenance()
        let uncollected = try WorkWorkspaceAdapter.adapt(index: nil, roots: [], provenance: provenance)
        XCTAssertNil(uncollected.metadata)
        XCTAssertEqual(uncollected.attribution.outcome, .notCollected)
        XCTAssertTrue(uncollected.attribution.records.isEmpty)
        provenance.didPublish(.sessionIndex)
        let index = SessionIndex(total: 1, sessions: [SessionInspectionFixtures.entry(workspace: "")])
        let result = try WorkWorkspaceAdapter.adapt(index: index, roots: [], provenance: provenance)
        XCTAssertTrue(try XCTUnwrap(result.metadata).records.isEmpty)
        XCTAssertTrue(result.attribution.records.isEmpty)
        let project = try XCTUnwrap(WorkProjectBuilder.build(sessions: index.sessions, worktrees: [], assessments: []).first)
        XCTAssertEqual(project.id, WorkProjectBuilder.unassignedID)
        XCTAssertNil(project.identity)
    }

    func testCoverageAndInvalidIdentityDoNotBecomeFalseFacts() throws {
        let good = SessionInspectionFixtures.entry(workspace: "/repo")
        let invalid = SessionInspectionFixtures.entry(workspace: "/other", source: "")
        let index = SessionIndex(total: 10, sessions: [good, invalid],
                                 coverage: SessionIndexCoverage(complete: true, stores: []))
        var provenance = WorkProvenance()
        provenance.didPublish(.sessionIndex)
        let result = try WorkWorkspaceAdapter.adapt(index: index, roots: [], provenance: provenance)
        XCTAssertEqual(result.metadata?.outcome, .partial)
        XCTAssertEqual(result.metadata?.coverage.state, .partial)
        XCTAssertEqual(result.metadata?.failures.first?.code, .malformed)
        XCTAssertEqual(result.metadata?.records.count, 1)
        XCTAssertEqual(result.attribution.records.count, 1)
        XCTAssertEqual(result.attribution.coverage.state, .unknown)
        XCTAssertEqual(result.attribution.records.first?.evidence.method, .workspaceFallback)
    }

    func testLogicalSessionIdentityIsDistinctFromPhysicalFallback() throws {
        let json: [String: Any] = [
            "tool": "Codex", "source": "/transcripts/a.jsonl", "workspace": "/repo",
            "kind": "session", "sizeBytes": 10, "lastActive": "2026-09-08",
            "sessionId": "logical-1", "artifactSources": ["/transcripts/a.jsonl", "/transcripts/b.jsonl"],
        ]
        let logical = try JSONDecoder().decode(SessionIndexEntry.self, from: JSONSerialization.data(withJSONObject: json))
        let physical = SessionInspectionFixtures.entry(tool: "Codex", workspace: "/repo", source: "logical-1")
        var provenance = WorkProvenance()
        provenance.didPublish(.sessionIndex)
        let result = try WorkWorkspaceAdapter.adapt(index: SessionIndex(total: 2, sessions: [logical, physical]),
                                                    roots: [], provenance: provenance)
        let records = try XCTUnwrap(result.metadata).records
        XCTAssertEqual(records[0].session.namespace, "logical-session")
        XCTAssertEqual(records[1].session.namespace, "session-artifact")
        XCTAssertNotEqual(records[0].session, records[1].session)
    }
}

@MainActor
final class WorkEvidencePublicationTests: XCTestCase {
    private func model() async -> ScanModel {
        let model = ScanModel(automaticallyScansStaleResults: false)
        for task in model.cancelTrackedApplicationTasks() { await task.value }
        return model
    }

    func testComputedProjectsPreserveRowsSelectionAndStableReferences() async throws {
        let model = await model()
        let sessions = [
            SessionInspectionFixtures.entry(workspace: "/Repo/.claude/worktrees/x", lastActive: "2026-09-08"),
            SessionInspectionFixtures.entry(workspace: "/Repo/", lastActive: "2026-09-07"),
            SessionInspectionFixtures.entry(workspace: ""),
            SessionInspectionFixtures.entry(workspace: "/repo-sibling", lastActive: "2026-09-06"),
        ]
        model.sessionIndex = SessionIndex(total: sessions.count, sessions: sessions)
        model.selectedProjectID = "/repo"
        model.selectedSessionSource = sessions[0].source
        let legacy = WorkProjectBuilder.build(sessions: sessions, worktrees: [], assessments: [])
        let first = model.workProjects
        XCTAssertEqual(first, legacy)
        XCTAssertEqual(first.map(\.id), ["/repo", "/repo-sibling", WorkProjectBuilder.unassignedID])
        XCTAssertEqual(first.map(\.name), legacy.map(\.name))
        XCTAssertEqual(first.map(\.sizeText), legacy.map(\.sizeText))
        XCTAssertEqual(first.map(\.conversationCount), legacy.map(\.conversationCount))
        XCTAssertEqual(WorkListPane.filter(first, search: "repo"), WorkListPane.filter(legacy, search: "repo"))
        XCTAssertEqual(first[0].identity?.comparisonKey, "/repo")
        XCTAssertEqual(first[0].workspaceAttributions.count, 2)
        XCTAssertNil(first.last?.identity)
        XCTAssertTrue(first.last?.workspaceAttributions.isEmpty == true)
        let refs = first.flatMap(\.workspaceAttributions).map(\.evidence.reference)
        for _ in 0..<5 {
            XCTAssertEqual(model.workProjects.flatMap(\.workspaceAttributions).map(\.evidence.reference), refs)
        }
        model.sessionIndexGeneration += 1
        model.sessionSearch = "repo"
        XCTAssertEqual(model.workProjects.flatMap(\.workspaceAttributions).map(\.evidence.reference), refs)
        XCTAssertEqual(model.selectedProjectID, "/repo")
        XCTAssertEqual(model.selectedSessionSource, sessions[0].source)
    }

    func testRootPublicationChangesOnlyCompositionProvenance() async throws {
        let model = await model()
        let session = SessionInspectionFixtures.entry(workspace: "/repo/nested/subdir")
        model.sessionIndex = SessionIndex(total: 1, sessions: [session])
        let before = try XCTUnwrap(model.workProjects.first?.workspaceAttributions.first)
        model.screeReport = ScreeReport(json: ["lineage": ["paths": [
            ["path": "/repo", "has_git": true], ["path": "/repo/nested", "has_git": true],
        ]]])
        let after = try XCTUnwrap(model.workProjects.first?.workspaceAttributions.first)
        XCTAssertEqual(before.project.comparisonKey, session.workspace)
        XCTAssertEqual(after.project.comparisonKey, "/repo/nested")
        XCTAssertEqual(before.workspace, after.workspace)
        XCTAssertNotEqual(before.evidence.reference, after.evidence.reference)
        XCTAssertEqual(after.inputRuns, model.workProvenance.inputRuns)
        let repeated = try XCTUnwrap(model.workProjects.first?.workspaceAttributions.first)
        XCTAssertEqual(after, repeated)
    }

    func testEveryBuilderInputPublicationRotatesCompositionButNotSessionRun() async throws {
        let model = await model()
        model.sessionIndex = SessionIndex(total: 1, sessions: [SessionInspectionFixtures.entry(workspace: "/repo")])
        let sessionRun = model.workProvenance.inputRuns[.sessionIndex]
        let updates: [(WorkInput, () -> Void)] = [
            (.screeReport, { model.screeReport = ScreeReport(json: [:]) }),
            (.repoAssessments, { model.repoAssessments = [] }),
            (.repoScanFailures, { model.repoScanFailures["/repo"] = "unreadable" }),
            (.reposNotScanned, { model.reposNotScanned.append("/other") }),
        ]
        for (input, update) in updates {
            let before = model.workProvenance.compositionRunID
            update()
            XCTAssertNotEqual(model.workProvenance.compositionRunID, before, input.rawValue)
            XCTAssertNotNil(model.workProvenance.inputRuns[input])
            XCTAssertEqual(model.workProvenance.inputRuns[.sessionIndex], sessionRun)
        }
        let before = try XCTUnwrap(model.workProjects.first { $0.path == "/repo" }?.workspaceAttributions.first)
        let index = model.sessionIndex
        model.sessionIndex = index
        let after = try XCTUnwrap(model.workProjects.first { $0.path == "/repo" }?.workspaceAttributions.first)
        XCTAssertNotEqual(before.workspace.evidence.reference, after.workspace.evidence.reference)
        XCTAssertNotEqual(before.evidence.reference, after.evidence.reference)
    }

    func testFailedRefreshDoesNotRelabelRetainedFactsAndCancelledWriteCannotRotateRuns() async throws {
        let model = await model()
        let index = SessionIndex(total: 1, sessions: [SessionInspectionFixtures.entry(workspace: "/repo")])
        model.refreshSessionIndex(using: { .success(index) })
        await model.sessionIndexTask?.value
        let first = try XCTUnwrap(model.workProjects.first?.workspaceAttributions.first)
        model.refreshSessionIndex(using: { .failure(.init(message: "unreadable")) })
        await model.sessionIndexTask?.value
        XCTAssertEqual(model.sessionIndexError, "unreadable")
        XCTAssertEqual(model.workProjects.first?.workspaceAttributions.first, first)

        // Supersede before the first task can publish. Generation stays a lifecycle
        // token, while only the accepted publication advances semantic provenance.
        model.refreshSessionIndex(using: { .success(SessionIndex(total: 0, sessions: [])) })
        let old = model.sessionIndexTask
        model.refreshSessionIndex(using: { .success(index) })
        await model.sessionIndexTask?.value
        let accepted = try XCTUnwrap(model.workProjects.first?.workspaceAttributions.first)
        await old?.value
        XCTAssertEqual(model.workProjects.first?.workspaceAttributions.first, accepted)
        XCTAssertNotEqual(first.workspace.evidence.reference, accepted.workspace.evidence.reference)
    }
}
