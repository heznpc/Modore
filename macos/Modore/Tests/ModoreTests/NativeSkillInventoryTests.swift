import Darwin
import Foundation
import XCTest
@testable import Modore

final class NativeSkillInventoryTests: XCTestCase {
    private var package: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func temporary() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return try NativeFileTree.resolved(home)
    }
    @discardableResult private func skill(_ home: URL, _ relative: String = ".codex/skills/example", body: String = "Alpha") throws -> URL {
        let path = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try "---\nname: example\nversion: 1\n---\n\(body)".write(to: path.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "support file".write(to: path.appendingPathComponent("support.txt"), atomically: true, encoding: .utf8)
        return path
    }
    private func request(_ manager: NativeSkillInventory, _ path: URL) throws -> [String: Any] {
        let rows = manager.inventory()
        let row = try XCTUnwrap(rows.first { $0["path"] as? String == path.path }, "expected \(path.path) rows \(rows)")
        return ["id": row["id"]!, "fingerprint": row["fingerprint"]!]
    }
    private func backups(_ snapshot: [String: Any]) -> [[String: Any]] { snapshot["backups"] as? [[String: Any]] ?? [] }
    private func python(_ home: URL, _ code: String, extra: [String] = []) throws -> [String: Any] {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-B", "-c", "import importlib.util,json,sys; from pathlib import Path; s=importlib.util.spec_from_file_location('reference',sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); manager=m.Skills(Path(sys.argv[2])); " + code,
            package.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/skill_inventory.py").path, home.path] + extra
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func testFingerprintsAndMetadataMatchPythonIncludingUnicodeAndLinks() throws {
        let home = try temporary(), path = try skill(home)
        try "지원 자료".write(to: path.appendingPathComponent("한글.txt"), atomically: true, encoding: .utf8)
        let alias = home.appendingPathComponent(".agents/skills/alias")
        try FileManager.default.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: path)
        let native = NativeSkillInventory(home: home).inventory()
        let reference = try python(home, "print(json.dumps(manager.status(),ensure_ascii=False))")
        let rows = try XCTUnwrap(reference["items"] as? [[String: Any]])
        XCTAssertEqual(native.count, rows.count)
        for row in native {
            let expected = try XCTUnwrap(rows.first { $0["id"] as? String == row["id"] as? String })
            for key in ["fingerprint", "hash", "name", "version", "link", "realPath", "path", "source", "host"] {
                XCTAssertEqual(row[key] as? String, expected[key] as? String, key)
            }
            XCTAssertEqual(row["variants"] as? Int, expected["variants"] as? Int)
        }
    }
    func testNativeDisablePythonRestoreAndPythonDisableNativeRestore() throws {
        let home = try temporary(), path = try skill(home), manager = NativeSkillInventory(home: home)
        let first = try XCTUnwrap(backups(try manager.disable(request(manager, path))).first)
        XCTAssertFalse(NativeFileTree.exists(path))
        _ = try python(home, "print(json.dumps(manager.restore({'id':sys.argv[3]})))", extra: [first["id"] as! String])
        XCTAssertEqual(try String(contentsOf: path.appendingPathComponent("support.txt")), "support file")
        let second = try python(home, "r=manager.inventory()[0]; print(json.dumps(manager.disable({'id':r['id'],'fingerprint':r['fingerprint']})))")
        let backup = try XCTUnwrap(backups(second).first { $0["state"] as? String == "disabled" })
        _ = try manager.restore(["id": backup["id"]!])
        XCTAssertTrue(NativeFileTree.exists(path.appendingPathComponent("SKILL.md")))
    }
    func testNativeRoundTripIncludesSettingsWithoutChangingThem() throws {
        let home = try temporary(), path = try skill(home), manager = NativeSkillInventory(home: home)
        let config = home.appendingPathComponent(".codex/config.toml")
        try "[features]\nhooks=false\n".write(to: config, atomically: true, encoding: .utf8)
        let backup = try XCTUnwrap(backups(try manager.disable(request(manager, path))).first)
        let bank = URL(fileURLWithPath: backup["backupPath"] as! String)
        XCTAssertEqual(try String(contentsOf: bank.appendingPathComponent("settings/0-config.toml")), try String(contentsOf: config))
        _ = try manager.restore(["id": backup["id"]!])
        XCTAssertEqual(try String(contentsOf: config), "[features]\nhooks=false\n")
        XCTAssertEqual(backups(manager.status()).first?["state"] as? String, "restored")
    }
    func testRelativeLinkRoundTripDoesNotChangeTarget() throws {
        let home = try temporary(), target = try skill(home, "external/example"), manager = NativeSkillInventory(home: home)
        let path = home.appendingPathComponent(".agents/skills/example")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertEqual(symlink("../../external/example", path.path), 0)
        let original = try Data(contentsOf: target.appendingPathComponent("SKILL.md"))
        let backup = try XCTUnwrap(backups(try manager.disable(request(manager, path))).first)
        XCTAssertFalse(NativeFileTree.exists(path))
        _ = try manager.restore(["id": backup["id"]!])
        XCTAssertEqual(try NativeFileTree.link(path), "../../external/example")
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("SKILL.md")), original)
    }
    func testStaleSelectionAndNestedLinkNeverMoveOriginal() throws {
        let home = try temporary(), path = try skill(home), manager = NativeSkillInventory(home: home)
        let selection = try request(manager, path)
        try "changed".write(to: path.appendingPathComponent("support.txt"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try manager.disable(selection))
        try FileManager.default.createSymbolicLink(at: path.appendingPathComponent("nested"), withDestinationURL: path.appendingPathComponent("support.txt"))
        XCTAssertThrowsError(try manager.disable(request(manager, path)))
        XCTAssertTrue(NativeFileTree.exists(path))
    }
    func testRestoreRejectsConflictingDanglingLinkAndTamperedContent() throws {
        let home = try temporary(), path = try skill(home), manager = NativeSkillInventory(home: home)
        let backup = try XCTUnwrap(backups(try manager.disable(request(manager, path))).first)
        let request: [String: Any] = ["id": backup["id"]!]
        XCTAssertEqual(symlink("/missing-skill-test", path.path), 0)
        XCTAssertThrowsError(try manager.restore(request))
        XCTAssertEqual(try NativeFileTree.link(path), "/missing-skill-test")
        try FileManager.default.removeItem(at: path)
        let bank = URL(fileURLWithPath: backup["backupPath"] as! String)
        try "tampered".write(to: bank.appendingPathComponent("content/SKILL.md"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try manager.restore(request))
        XCTAssertFalse(NativeFileTree.exists(path))
    }
    func testRestoreRejectsChangedLinkTarget() throws {
        let home = try temporary(), target = try skill(home, "external/example"), manager = NativeSkillInventory(home: home)
        let path = home.appendingPathComponent(".codex/skills/example")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
        let backup = try XCTUnwrap(backups(try manager.disable(request(manager, path))).first)
        try "changed".write(to: target.appendingPathComponent("support.txt"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try manager.restore(["id": backup["id"]!]))
        XCTAssertFalse(NativeFileTree.exists(path))
    }
    func testCorruptBackupDoesNotHideValidBackups() throws {
        let home = try temporary(), path = try skill(home), manager = NativeSkillInventory(home: home)
        let backup = try XCTUnwrap(backups(try manager.disable(request(manager, path))).first)
        let corrupt = manager.bank.appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try "{}".write(to: corrupt.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let status = manager.status()
        XCTAssertEqual(backups(status).map { $0["id"] as! String }, [backup["id"] as! String])
        XCTAssertFalse((status["warnings"] as? [String] ?? []).isEmpty)
    }
    func testNoReplaceAndSymlinkParentAreRejected() throws {
        let home = try temporary(), a = home.appendingPathComponent("a"), b = home.appendingPathComponent("b")
        try Data("A".utf8).write(to: a); try Data("B".utf8).write(to: b)
        XCTAssertThrowsError(try NativeFileTree.renameExclusive(a, b))
        XCTAssertEqual(try String(contentsOf: b), "B")
        let alias = home.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: home)
        XCTAssertThrowsError(try NativeFileTree.renameExclusive(alias.appendingPathComponent("a"), home.appendingPathComponent("c")))
        XCTAssertTrue(NativeFileTree.exists(a))
    }
    func testSpecialFilesCyclesAndOversizedMetadataStayVisible() throws {
        let home = try temporary(), path = try skill(home), manager = NativeSkillInventory(home: home)
        let md = path.appendingPathComponent("SKILL.md")
        try FileManager.default.removeItem(at: md); XCTAssertEqual(mkfifo(md.path, 0o600), 0)
        XCTAssertFalse((manager.inventory().first?["error"] as? String ?? "").isEmpty)
        try FileManager.default.removeItem(at: md)
        try Data(repeating: 120, count: 2 * 1024 * 1024 + 1).write(to: md)
        XCTAssertFalse((manager.inventory().first?["error"] as? String ?? "").isEmpty)
        let cycle = home.appendingPathComponent(".codex/skills/cycle")
        XCTAssertEqual(symlink("cycle", cycle.path), 0)
        XCTAssertFalse((manager.inventory().first { $0["path"] as? String == cycle.path }?["error"] as? String ?? "").isEmpty)
    }
    func testLateReplacementAtMoveIsPutBack() throws {
        let home = try temporary(), path = try skill(home), manager = NativeSkillInventory(home: home)
        manager.rename = { source, target in
            if source.path == path.path { try "late change".write(to: source.appendingPathComponent("support.txt"), atomically: true, encoding: .utf8) }
            try NativeFileTree.renameExclusive(source, target)
        }
        XCTAssertThrowsError(try manager.disable(request(manager, path)))
        XCTAssertEqual(try String(contentsOf: path.appendingPathComponent("support.txt")), "late change")
        XCTAssertEqual(backups(manager.status()).first?["state"] as? String, "failed")
    }
    func testInterruptedFinalWritesRemainRecoverable() throws {
        let home = try temporary(), path = try skill(home), manager = NativeSkillInventory(home: home)
        manager.beforeSave = { if $0["state"] as? String == "disabled" { throw POSIXError(.ENOSPC) } }
        XCTAssertThrowsError(try manager.disable(request(manager, path)))
        let backup = try XCTUnwrap(backups(manager.status()).first)
        XCTAssertEqual(backup["state"] as? String, "needsAttention")
        XCTAssertFalse(NativeFileTree.exists(path))
        manager.beforeSave = { if $0["state"] as? String == "restored" { throw POSIXError(.ENOSPC) } }
        XCTAssertThrowsError(try manager.restore(["id": backup["id"]!]))
        XCTAssertTrue(NativeFileTree.exists(path))
        XCTAssertEqual(backups(manager.status()).first?["state"] as? String, "restored")
        manager.beforeSave = nil
        _ = try manager.restore(["id": backup["id"]!])
        XCTAssertEqual(backups(manager.status()).first?["error"] as? String, "")
    }

    func testTOMLValidatesEntireDocumentBeforeEnabledClaim() throws {
        XCTAssertEqual(try NativeTOML.pluginFlags("[plugins.\"sample@market\"]\nenabled=true\n"), ["sample@market": true])
        XCTAssertThrowsError(try NativeTOML.pluginFlags("[plugins.\"sample@market\"]\nenabled=true\nbroken=["))
    }
}
