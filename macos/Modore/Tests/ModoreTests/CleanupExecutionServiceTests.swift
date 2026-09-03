import Foundation
import XCTest
@testable import Modore

final class CleanupExecutionServiceTests: XCTestCase {
    private let baseFiles = ["cleanup": Data("sealed cleanup".utf8)]

    private func projectRequest() throws -> CleanupExecutionRequest {
        let item = try XCTUnwrap(StorageItem(json: [
            "risk": "warning",
            "kind": "project_residue",
            "label": "Swift build",
            "sizeGB": 1,
            "path": "/Users/test/App/.build",
            "action": "정리",
            "measureStatus": "ok",
            "cleanupId": "project_residue",
        ]))
        return try XCTUnwrap(CleanupExecutionRequest(item: item))
    }

    private func transientRequest() throws -> CleanupExecutionRequest {
        let item = try XCTUnwrap(StorageItem(json: [
            "risk": "warning",
            "kind": "transient_workspace",
            "label": "temporary workspace",
            "sizeGB": 1,
            "path": "/private/tmp/temporary-workspace",
            "action": "정리",
            "measureStatus": "ok",
            "cleanupId": "transient_workspace",
        ]))
        return try XCTUnwrap(CleanupExecutionRequest(item: item))
    }

    private func readyPreview(
        recipeID: String = "npm_cache",
        token: String = String(repeating: "a", count: 64)
    ) throws -> CleanupPreview {
        try XCTUnwrap(CleanupPreview(protocolText: """
        version\t1
        operation\tpreview
        status\tready
        recipeId\t\(recipeID)
        label\tcleanup
        approvalToken\t\(token)
        """))
    }

    func testFixedRecipePreviewUsesOnlySealedBaseFiles() throws {
        let invocation = try XCTUnwrap(CleanupExecutionService.previewInvocation(
            recipeID: "npm_cache",
            request: nil,
            pinnedFiles: baseFiles
        ))

        XCTAssertEqual(invocation.arguments, [])
        XCTAssertEqual(invocation.pinnedFiles, baseFiles)
    }

    func testProjectResidueRequiresMatchingPathBoundRequest() throws {
        let request = try projectRequest()

        XCTAssertNil(CleanupExecutionService.previewInvocation(
            recipeID: "project_residue",
            request: nil,
            pinnedFiles: baseFiles
        ))
        XCTAssertNil(CleanupExecutionService.previewInvocation(
            recipeID: "npm_cache",
            request: request,
            pinnedFiles: baseFiles
        ))

        let invocation = try XCTUnwrap(CleanupExecutionService.previewInvocation(
            recipeID: "project_residue",
            request: request,
            pinnedFiles: baseFiles
        ))
        XCTAssertEqual(
            invocation.arguments,
            ["--request-file", "@pch-pinned:cleanup_request"]
        )
        XCTAssertEqual(invocation.pinnedFiles["cleanup_request"], request.protocolData)
        XCTAssertEqual(invocation.pinnedFiles["cleanup"], baseFiles["cleanup"])
    }

    func testTransientWorkspaceAlsoRequiresPathBoundRequest() throws {
        let request = try transientRequest()

        XCTAssertNil(CleanupExecutionService.previewInvocation(
            recipeID: "transient_workspace",
            request: nil,
            pinnedFiles: baseFiles
        ))
        let invocation = try XCTUnwrap(CleanupExecutionService.previewInvocation(
            recipeID: "transient_workspace",
            request: request,
            pinnedFiles: baseFiles
        ))

        XCTAssertEqual(
            invocation.arguments,
            ["--request-file", "@pch-pinned:cleanup_request"]
        )
        XCTAssertEqual(invocation.pinnedFiles["cleanup_request"], request.protocolData)
    }

    func testCallerCannotReplaceReservedRequestFile() throws {
        let request = try projectRequest()
        var colliding = baseFiles
        colliding["cleanup_request"] = Data("attacker".utf8)

        XCTAssertNil(CleanupExecutionService.previewInvocation(
            recipeID: "project_residue",
            request: request,
            pinnedFiles: colliding
        ))
    }

    func testExecutionPinsApprovalTokenAndOwnerApprovalArguments() throws {
        let preview = try readyPreview()
        let invocation = try XCTUnwrap(CleanupExecutionService.executionInvocation(
            preview: preview,
            request: nil,
            pinnedFiles: baseFiles
        ))

        XCTAssertEqual(invocation.pinnedFiles["approval_token"], Data(preview.approvalToken.utf8))
        XCTAssertEqual(invocation.pinnedFiles["cleanup"], baseFiles["cleanup"])
        XCTAssertEqual(invocation.arguments, [
            "--owner-approved",
            "--approval-token-file", "@pch-pinned:approval_token",
        ])
    }

    func testProjectExecutionPinsBothApprovalAndPathBoundRequest() throws {
        let request = try projectRequest()
        let preview = try readyPreview(recipeID: "project_residue")

        let invocation = try XCTUnwrap(CleanupExecutionService.executionInvocation(
            preview: preview,
            request: request,
            pinnedFiles: baseFiles
        ))

        XCTAssertEqual(
            invocation.pinnedFiles["approval_token"],
            Data(preview.approvalToken.utf8)
        )
        XCTAssertEqual(invocation.pinnedFiles["cleanup_request"], request.protocolData)
        XCTAssertEqual(invocation.arguments, [
            "--owner-approved",
            "--approval-token-file", "@pch-pinned:approval_token",
            "--request-file", "@pch-pinned:cleanup_request",
        ])
        XCTAssertFalse(invocation.arguments.contains(preview.approvalToken))
        XCTAssertFalse(invocation.arguments.contains(request.target))
    }

    func testExecutionRejectsInvalidOrPreexistingApprovalToken() throws {
        let invalid = try readyPreview(token: "short")
        XCTAssertNil(CleanupExecutionService.executionInvocation(
            preview: invalid,
            request: nil,
            pinnedFiles: baseFiles
        ))

        let valid = try readyPreview()
        var colliding = baseFiles
        colliding["approval_token"] = Data("attacker".utf8)
        XCTAssertNil(CleanupExecutionService.executionInvocation(
            preview: valid,
            request: nil,
            pinnedFiles: colliding
        ))
    }
}
