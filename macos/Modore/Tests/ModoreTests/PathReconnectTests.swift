import Foundation
import XCTest
@testable import Modore

final class PathReconnectTests: XCTestCase {
    private let original = URL(fileURLWithPath: "/Users/example/Documents/project-notes")
    private let target = URL(fileURLWithPath: "/Volumes/Example/Working/project-notes")
    private let identifier = String(repeating: "a", count: 48)

    private func planObject() -> [String: Any] {
        ["schemaVersion": 1, "planID": identifier, "originalPath": original.path,
         "targetPath": target.path, "targetKind": "file", "bytes": 42,
         "sha256": String(repeating: "b", count: 64), "createdAt": 1_000, "expiresAt": 4_600,
         "warnings": [], "impact": "fixture"]
    }

    private func connectionObject() -> [String: Any] {
        ["schemaVersion": 1, "connectionID": identifier, "status": "connected",
         "originalPath": original.path, "targetPath": target.path, "targetKind": "file",
         "receiptPath": "/Users/example/Library/Application Support/Modore/path-reconnect/receipt.json",
         "warnings": [], "reason": "fixture"]
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ object: [String: Any]) throws -> Value {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }

    func testPreviewBindsBothPathsAndValidatesIdentityAndEvidence() throws {
        let valid = try decode(PathReconnectPlan.self, planObject())
        XCTAssertTrue(valid.matches(original: original, target: target))
        XCTAssertFalse(valid.matches(original: target, target: original))
        for (key, value) in [("planID", "../plan" as Any), ("expiresAt", 999),
                             ("bytes", -1), ("sha256", "invalid"), ("targetKind", "symlink")] {
            var object = planObject()
            object[key] = value
            XCTAssertFalse(try decode(PathReconnectPlan.self, object).matches(original: original, target: target), key)
        }
    }

    func testMutationResponseMustMatchPreviewAndUndoMustMatchConnection() throws {
        let plan = try decode(PathReconnectPlan.self, planObject())
        let connection = try decode(PathReconnectConnection.self, connectionObject())
        XCTAssertTrue(connection.matches(plan))
        XCTAssertTrue(connection.canDisconnect)
        for status in ["target-replaced", "recovery-needed", "ssd-unavailable"] {
            var changed = connectionObject()
            changed["status"] = status
            XCTAssertFalse(try decode(PathReconnectConnection.self, changed).matches(plan), status)
        }
        var object = connectionObject()
        object["status"] = "disconnected"
        let undone = try decode(PathReconnectConnection.self, object)
        XCTAssertTrue(undone.confirmsUndo(of: connection))
        XCTAssertFalse(undone.matches(plan))
        XCTAssertFalse(undone.canDisconnect)
        object["targetPath"] = "/Volumes/Example/Working/another-file"
        XCTAssertFalse(try decode(PathReconnectConnection.self, object).confirmsUndo(of: connection))
    }

    func testInventoryRejectsDuplicatesMalformedPathsAndUnknownStates() throws {
        let candidate: [String: Any] = ["originalPath": original.path, "targetPath": target.path,
                                      "receiptPath": "/fixture/cleanup.json", "bytes": 42]
        var object: [String: Any] = ["schemaVersion": 1, "connections": [connectionObject()],
                                     "candidates": [candidate], "warnings": []]
        XCTAssertTrue(try decode(PathReconnectInventory.self, object).valid)
        object["candidates"] = [candidate, candidate]
        XCTAssertFalse(try decode(PathReconnectInventory.self, object).valid)
        object["candidates"] = [candidate]
        var connection = connectionObject()
        connection["status"] = "resumed"
        object["connections"] = [connection]
        XCTAssertFalse(try decode(PathReconnectInventory.self, object).valid)
        connection["status"] = "connected"
        connection["originalPath"] = "/Users/example/../other/file"
        object["connections"] = [connection]
        XCTAssertFalse(try decode(PathReconnectInventory.self, object).valid)
    }

    func testHealthOnlyOffersUndoForRecognizedOwnedLinkStates() throws {
        for status in ["connected", "ssd-unavailable", "target-replaced", "conflict", "original-missing", "recovery-needed", "disconnected"] {
            var object = connectionObject()
            object["status"] = status
            let value = try decode(PathReconnectConnection.self, object)
            XCTAssertTrue(value.valid, status)
            XCTAssertEqual(value.canDisconnect, ["connected", "ssd-unavailable", "target-replaced"].contains(status), status)
        }
    }

    func testSealedBackendRunsThroughRealProcessRunner() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("modore-reconnect-pin-\(UUID())")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let repository = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let identity = try XCTUnwrap(FilesystemIdentity.directory(at: root))
        let context = RuntimeExecutionContext(runtimeRoot: root, outputRoot: root,
            configurationURL: root.appendingPathComponent("config.json"), usesBundledRuntime: true,
            runtimeRootIdentity: identity, outputRootIdentity: identity, signedBundleURL: nil,
            sealedRuntimeFiles: ["scripts/path_reconnect.py": try Data(contentsOf: repository.appendingPathComponent("scripts/path_reconnect.py"))])
        let result = try await SessionRecoveryService.invoke(execution: context, script: "path_reconnect.py",
            arguments: ["--help"], timeout: 30)
        XCTAssertTrue(result.succeeded, result.output)
        XCTAssertTrue(result.output.contains("preview"))
    }
}
