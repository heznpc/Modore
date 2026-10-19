import Darwin
import Foundation
import XCTest
@testable import Modore

final class NativeBuildLifecycleTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return try NativeFileTree.resolved(root)
    }
    private func python(_ code: String, args: [String]) throws -> [String: Any] {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = package.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/build_lifecycle.py")
        let result = try NativeCommand.run("/usr/bin/python3", ["-I", "-B", "-c", "import importlib.util,json,sys; from pathlib import Path; spec=importlib.util.spec_from_file_location('reference',sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m); " + code, script.path] + args)
        XCTAssertEqual(result.status, 0, result.errorText)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: result.output) as? [String: Any])
    }
    private func record(_ manager: NativeBuildLifecycle, home: URL, status: String = "verified", evidence: Bool = false, time: Double = 1) throws -> (String, String, URL) {
        let id = UUID().uuidString.lowercased(), artifactID = UUID().uuidString.lowercased()
        let repo = home.appendingPathComponent("repo"), output = repo.appendingPathComponent("build/" + id), artifact = output.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        try Data("owned build bytes\n".utf8).write(to: artifact.appendingPathComponent(evidence ? "diagnostic.log" : "object.bin"))
        let seal = try JSONSerialization.jsonObject(with: JSONEncoder().encode(NativeArtifactEvidence.seal(artifact)))
        try SecureLocalFileIO.ensurePrivateDirectory(manager.store.root)
        try manager.store.save(["id": id, "repository": repo.path, "output": output.path, "startedAt": time, "finishedAt": time + 1,
            "status": status, "pid": 999999, "processIdentity": "inactive fixture", "validation": "fixture verified", "installedLinks": [],
            "artifacts": [["id": artifactID, "kind": "scratch", "path": artifact.path, "identity": try NativeArtifactEvidence.identity(artifact), "seal": seal, "removedAt": NSNull()]]], name: id + ".json")
        return (id, artifactID, artifact)
    }
    func testSealMatchesPythonWithUnicodeLinksAndEvidence() throws {
        let root = try temporary(), folder = root.appendingPathComponent("evidence.trace")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("native bytes\n".utf8).write(to: folder.appendingPathComponent("한글.txt"))
        XCTAssertEqual(symlink("/outside/never-read", folder.appendingPathComponent("reference").path), 0)
        let native = try NativeArtifactEvidence.seal(folder), reference = try python("print(json.dumps(m.seal(Path(sys.argv[2]))))", args: [folder.path])
        XCTAssertEqual(native.digest, reference["digest"] as? String); XCTAssertEqual(native.bytes, reference["bytes"] as? Int64)
        XCTAssertTrue(native.evidence); XCTAssertEqual(native.evidence, reference["evidence"] as? Bool)
    }
    func testReportMatchesPythonPreservationPolicy() throws {
        let home = try temporary(), manager = NativeBuildLifecycle(home: home); manager.usage = { [] }; manager.processIdentity = { _ in nil }
        _ = try record(manager, home: home)
        _ = try record(manager, home: home, status: "failed", time: 2)
        _ = try record(manager, home: home, evidence: true, time: 3)
        let native = try manager.invoke(["arguments": ["report"]])
        let reference = try python("m.usage_snapshot=lambda: []; m.process_identity=lambda _: None; m.CACHE=Path(sys.argv[3]); print(json.dumps(m.Store(Path(sys.argv[2])).report()))", args: [manager.store.root.path, manager.cache.path])
        let rows = try XCTUnwrap(native["items"] as? [[String: Any]]), expected = try XCTUnwrap(reference["items"] as? [[String: Any]])
        XCTAssertEqual(rows.count, expected.count)
        for row in rows {
            let original = try XCTUnwrap(expected.first { $0["id"] as? String == row["id"] as? String })
            for key in ["id", "runID", "kind", "path", "reason", "status", "validation"] { XCTAssertEqual(row[key] as? String, original[key] as? String, key) }
            XCTAssertEqual(row["eligible"] as? Bool, original["eligible"] as? Bool)
        }
    }
    func testExplicitReclaimRemovesOnlySelectedUnchangedOwnedProduct() throws {
        let home = try temporary(), manager = NativeBuildLifecycle(home: home); manager.usage = { [] }
        let (_, id, path) = try record(manager, home: home), (_, _, evidence) = try record(manager, home: home, evidence: true, time: 2)
        let unknown = path.deletingLastPathComponent().appendingPathComponent("unknown")
        try Data("preserve".utf8).write(to: unknown)
        XCTAssertThrowsError(try manager.invoke(["arguments": ["reclaim"]]))
        let report = try manager.invoke(["arguments": ["reclaim", "--artifact-id", id]])
        XCTAssertFalse(NativeFileTree.exists(path)); XCTAssertTrue(NativeFileTree.exists(evidence))
        XCTAssertEqual(try String(contentsOf: unknown), "preserve")
        XCTAssertEqual((report["items"] as? [[String: Any]])?.first { $0["id"] as? String == id }?["reason"] as? String, "회수 완료")
    }
    func testChangedContentUseRecheckAndCorruptReceiptsProtectProducts() throws {
        let home = try temporary(), manager = NativeBuildLifecycle(home: home)
        let (_, id, path) = try record(manager, home: home)
        var observations = 0
        manager.usage = { observations += 1; return observations == 1 ? [] : [path.appendingPathComponent("object.bin").path] }
        _ = try manager.invoke(["arguments": ["reclaim", "--artifact-id", id]])
        XCTAssertTrue(NativeFileTree.exists(path))
        manager.usage = { [] }
        try Data("changed".utf8).write(to: path.appendingPathComponent("object.bin"))
        let changed = try manager.invoke(["arguments": ["report"]])
        XCTAssertEqual((changed["items"] as? [[String: Any]])?.first?["eligible"] as? Bool, false)
        try Data("not JSON".utf8).write(to: manager.store.root.appendingPathComponent(UUID().uuidString.lowercased() + ".json"))
        let corrupt = try manager.invoke(["arguments": ["report"]])
        XCTAssertFalse((corrupt["warnings"] as? [String] ?? []).isEmpty)
    }
    func testHardLinksAndSpecialFilesCannotBeSealedOrRemoved() throws {
        let root = try temporary(), folder = root.appendingPathComponent("product")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("data"), other = root.appendingPathComponent("other")
        try Data("keep".utf8).write(to: file); XCTAssertEqual(link(file.path, other.path), 0)
        XCTAssertThrowsError(try NativeArtifactEvidence.seal(folder)); XCTAssertEqual(try String(contentsOf: other), "keep")
        try FileManager.default.removeItem(at: other); try FileManager.default.removeItem(at: file)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0); XCTAssertThrowsError(try NativeArtifactEvidence.seal(folder))
    }
}
