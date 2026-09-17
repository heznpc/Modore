import XCTest
@testable import Modore

final class AssetRetirementServiceTests: XCTestCase {
    @MainActor
    func testPinnedEngineRunsRealLocalRetirement() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let execution = try XCTUnwrap(RuntimeWorkspace.prepareExecution(
            projectRoot: root,
            environment: ["PCH_DEVELOPMENT_MODE": "1", "PCH_PROJECT_DIR": root.path],
            resourceURL: nil
        ))
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("modore-retirement-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        func git(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", fixture.path] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
        }
        try git(["init", "-q"])
        try Data(".env\n".utf8).write(to: fixture.appendingPathComponent(".gitignore"))
        try Data("keep me".utf8).write(to: fixture.appendingPathComponent(".env"))
        try Data("remove me".utf8).write(to: fixture.appendingPathComponent("source"))
        let preview = try await AssetRetirementService.invoke(execution: execution, request: [
            "action": "preview", "items": [["path": fixture.path, "local": true, "archive": false]]
        ])
        defer {
            for suffix in ["json", "lock", "journal", "cancel"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: preview.receipt)
                    .deletingPathExtension().appendingPathExtension(suffix))
            }
        }
        let ids = preview.items.map(\.id)
        _ = try await AssetRetirementService.invoke(execution: execution, request: [
            "action": "approve", "transaction": preview.id, "ids": ids
        ])
        let result = try await AssetRetirementService.invoke(execution: execution, request: [
            "action": "execute", "transaction": preview.id, "ids": ids
        ])
        XCTAssertEqual(result.items.first?.localMutation, "succeeded")
        XCTAssertEqual(result.items.first?.localVerification, "verified")
        XCTAssertEqual(try String(contentsOf: fixture.appendingPathComponent(".env")), "keep me")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("source").path))
    }
}
