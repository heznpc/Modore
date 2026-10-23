import Darwin
import Foundation
import XCTest
import ZIPFoundation
@testable import Modore

final class NativeSessionRecoveryTests: XCTestCase {
    private func fixture() throws -> (URL, URL, URL, NativeSessionBackup.Manifest) {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: raw) }
        let root = try NativeFileTree.resolved(raw), home = root.appendingPathComponent("home"), source = home.appendingPathComponent(".codex/sessions/session.jsonl")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"type\":\"user\",\"message\":{\"content\":\"recovery fixture content\"}}\n".utf8).write(to: source)
        let archive = root.appendingPathComponent("backup.zip")
        _ = try NativeSessionBackup.create(source: source, home: home, destination: archive, includeSensitive: true)
        let manifest = try NativeSessionBackup.withArchive(archive) { try NativeSessionBackup.verify(fd: $0) }
        return (root, home, archive, manifest)
    }
    private func abandon(_ root: URL, archive: URL, manifest: NativeSessionBackup.Manifest, published: Bool = false) throws -> URL {
        let transaction = try NativeRestoreTransaction(parent: root, name: "restored"), zip = try Archive(url: archive, accessMode: .read)
        for file in manifest.files {
            try transaction.install(file, entry: try XCTUnwrap(zip["payload/" + file.path]), archive: zip)
        }
        if published { try transaction.validate(manifest.files); try transaction.publish() }
        return root.appendingPathComponent(transaction.guardName)
    }
    private func inspection(_ archive: URL, root: URL, home: URL) throws -> [String: Any] {
        let receipt = try NativeSessionBackup.inspectRecovery(archive: archive, destination: root.appendingPathComponent("restored"), home: home)
        return try XCTUnwrap(receipt["recovery"] as? [String: Any])
    }
    func testPreviewDoesNotMutateAndResumeRecreatesOnlyVerifiedNativeStage() throws {
        let (root, home, archive, manifest) = try fixture(), ledger = try abandon(root, archive: archive, manifest: manifest)
        let journal = try Data(contentsOf: ledger.appendingPathComponent("journal.jsonl"))
        let preview = try inspection(archive, root: root, home: home)
        XCTAssertEqual(preview["status"] as? String, "native"); XCTAssertEqual(preview["canResume"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: ledger.appendingPathComponent("journal.jsonl")), journal)
        XCTAssertFalse(NativeFileTree.exists(root.appendingPathComponent("restored")))
        let receipt = try NativeSessionBackup.resume(archive: archive, destination: root.appendingPathComponent("restored"), home: home)
        XCTAssertEqual(receipt["status"] as? String, "restored"); XCTAssertFalse(NativeFileTree.exists(ledger))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("restored/" + manifest.sourceRelative)), try Data(contentsOf: home.appendingPathComponent(manifest.sourceRelative)))
    }
    func testPublishedNativeRootIsVerifiedAndFinishedWithoutReplacement() throws {
        let (root, home, archive, manifest) = try fixture(), ledger = try abandon(root, archive: archive, manifest: manifest, published: true)
        let destination = root.appendingPathComponent("restored"), identity = try NativeFileTree.metadata(destination).st_ino
        XCTAssertEqual(try inspection(archive, root: root, home: home)["status"] as? String, "published")
        _ = try NativeSessionBackup.resume(archive: archive, destination: destination, home: home)
        XCTAssertEqual(try NativeFileTree.metadata(destination).st_ino, identity)
        XCTAssertFalse(NativeFileTree.exists(ledger)); try NativeSessionBackup.verifyRestored(destination, manifest: manifest)
    }
    func testForeignOrModifiedDataIsPreservedAndRequiresReview() throws {
        let (root, home, archive, manifest) = try fixture(), ledger = try abandon(root, archive: archive, manifest: manifest)
        let foreign = ledger.appendingPathComponent(".restore-root/foreign")
        try Data("preserve me".utf8).write(to: foreign)
        let preview = try inspection(archive, root: root, home: home)
        XCTAssertEqual(preview["status"] as? String, "manual"); XCTAssertEqual(preview["canResume"] as? Bool, false)
        XCTAssertThrowsError(try NativeSessionBackup.resume(archive: archive, destination: root.appendingPathComponent("restored"), home: home))
        XCTAssertEqual(try String(contentsOf: foreign), "preserve me")
    }
    private func legacy(_ root: URL, archive: URL) throws -> URL {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = package.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/scree.py")
        let code = """
        import importlib.util,json,sys,os,zipfile
        from pathlib import Path
        spec=importlib.util.spec_from_file_location('reference',sys.argv[1]); m=importlib.util.module_from_spec(spec); sys.modules[spec.name]=m; spec.loader.exec_module(m)
        parent=Path(sys.argv[2]); archive=Path(sys.argv[3]); z=zipfile.ZipFile(archive); manifest=m._backup_verify_open(z)
        pfd=os.open(parent,os.O_RDONLY|os.O_DIRECTORY); ledger=m._RestoreLedger(parent,pfd,'restored'); os.close(pfd)
        ledger.create_root(); ledger.install_recovery_plan(manifest['files']); entry=manifest['files'][0]
        directory=str(Path(entry['path']).parent); parent_fd=ledger.open_directory(directory,create=False)
        fd,_=ledger.create_owned_regular(directory,Path(entry['path']).name,entry['size'],entry['sha256'],parent_fd)
        os.write(fd,b'partial'); os.fsync(fd); os.close(fd); os.close(parent_fd)
        print(json.dumps({'ledger':str(parent/ledger.guard_name)})); ledger.close(); z.close()
        """
        let result = try NativeCommand.run("/usr/bin/python3", ["-I", "-B", "-c", code, script.path, root.path, archive.path])
        XCTAssertEqual(result.status, 0, result.errorText)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: result.output) as? [String: Any])
        return URL(fileURLWithPath: try XCTUnwrap(object["ledger"] as? String))
    }
    func testPythonSchemaThreePartialRestoreCanBeInspectedAndRecoveredNatively() throws {
        let (root, home, archive, manifest) = try fixture(), ledger = try legacy(root, archive: archive)
        let preview = try inspection(archive, root: root, home: home)
        XCTAssertEqual(preview["status"] as? String, "legacy", preview["reason"] as? String ?? "")
        XCTAssertEqual(preview["canResume"] as? Bool, true)
        _ = try NativeSessionBackup.resume(archive: archive, destination: root.appendingPathComponent("restored"), home: home)
        XCTAssertFalse(NativeFileTree.exists(ledger))
        try NativeSessionBackup.verifyRestored(root.appendingPathComponent("restored"), manifest: manifest)
    }
    func testLegacyUnknownFilesAreNeverAdoptedForCleanup() throws {
        let (root, home, archive, _) = try fixture(), ledger = try legacy(root, archive: archive)
        let foreign = ledger.appendingPathComponent(".restore-root/foreign")
        try Data("keep".utf8).write(to: foreign)
        XCTAssertEqual(try inspection(archive, root: root, home: home)["canResume"] as? Bool, false)
        XCTAssertThrowsError(try NativeSessionBackup.resume(archive: archive, destination: root.appendingPathComponent("restored"), home: home))
        XCTAssertEqual(try String(contentsOf: foreign), "keep")
    }
    func testRealCLIAndWorkerVerifyTheSameArchiveAndCLIRejectsRuntimeOverrides() throws {
        let (_, _, archive, _) = try fixture()
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Modore")
        let result = try NativeCommand.run(executable.path, [NativeCLI.argument, "sessions", "backup-verify", archive.path])
        XCTAssertEqual(result.status, 0, result.errorText)
        let receipt = try JSONDecoder().decode(SessionBackupReceipt.self, from: result.output)
        XCTAssertEqual(receipt.status, "verified"); XCTAssertEqual(receipt.fileCount, 1)
        let invalid = try NativeCommand.run(executable.path, [NativeCLI.argument, "sessions", "backup-verify", archive.path, "--home", "/tmp/example"])
        XCTAssertNotEqual(invalid.status, 0)
    }
}
