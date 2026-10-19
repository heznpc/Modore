import Darwin
import Foundation
import XCTest
import ZIPFoundation
@testable import Modore

final class NativeSessionBackupTests: XCTestCase {
    private var package: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try NativeFileTree.resolved(root)
    }
    private func write(_ root: URL, _ name: String, _ text: String = "{\"type\":\"user\",\"message\":{\"content\":\"original text\"}}\n") throws -> URL {
        let path = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: path); return path
    }
    private func python(_ home: URL, _ code: String, extra: [String] = []) throws -> [String: Any] {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-B", "-c", "import importlib.util,json,sys; from pathlib import Path; s=importlib.util.spec_from_file_location('scree_reference',sys.argv[1]); m=importlib.util.module_from_spec(s); sys.modules[s.name]=m; s.loader.exec_module(m); home=Path(sys.argv[2]); " + code,
            package.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/scree.py").path, home.path] + extra
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func verify(_ archive: URL) throws -> NativeSessionBackup.Manifest { try NativeSessionBackup.withArchive(archive) { try NativeSessionBackup.verify(fd: $0) } }
    func testClaudeBackupIsReadableAndRestorableByPython() throws {
        let root = try temporary(), home = root.appendingPathComponent("home"), relative = ".claude/projects/project/session.jsonl"
        let source = try write(home, relative)
        _ = try write(home, ".claude/projects/project/session/subagents/agent.jsonl")
        _ = try write(home, ".claude/file-history/session/revision", "original snapshot")
        let archive = root.appendingPathComponent("native.zip")
        let receipt = try NativeSessionBackup.create(source: source, home: home, destination: archive, includeSensitive: true)
        XCTAssertEqual(receipt["fileCount"] as? Int, 3)
        let reference = try python(home, "print(json.dumps(m.verify_session_backup(Path(sys.argv[3]))))", extra: [archive.path])
        XCTAssertEqual(reference["fileCount"] as? Int, 3)
        let destination = root.appendingPathComponent("python-restored")
        _ = try python(home, "print(json.dumps(m.restore_session_backup(Path(sys.argv[3]),Path(sys.argv[4]))))", extra: [archive.path, destination.path])
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(relative)), try Data(contentsOf: source))
        XCTAssertEqual(try NativeFileTree.metadata(archive).st_mode & 0o777, 0o600)
    }
    func testPythonBackupIsReadableAndRestorableNatively() throws {
        let root = try temporary(), home = root.appendingPathComponent("home"), relative = ".codex/sessions/2026/10/session.jsonl"
        let source = try write(home, relative), archive = root.appendingPathComponent("python.zip")
        _ = try python(home, "print(json.dumps(m.build_session_backup(Path(sys.argv[3]),home,Path(sys.argv[4]),include_sensitive=True)))", extra: [source.path, archive.path])
        XCTAssertEqual(try verify(archive).provider, "Codex")
        let destination = root.appendingPathComponent("native-restored")
        let receipt = try NativeSessionBackup.restore(archive: archive, destination: destination, home: home)
        XCTAssertEqual(receipt["status"] as? String, "restored")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(relative)), try Data(contentsOf: source))
        XCTAssertEqual(try NativeFileTree.metadata(destination).st_mode & 0o777, 0o700)
        XCTAssertEqual(try NativeFileTree.metadata(destination.appendingPathComponent(relative)).st_mode & 0o777, 0o600)
    }
    func testDesktopUnitIncludesOnlyOwnedSidecarsAndPreservesLeafLinks() throws {
        let root = try temporary(), home = root.appendingPathComponent("home")
        let relative = NativeSessionBackup.desktopPrefix + "account/team/local_example.json"
        let metadata: [String: Any] = ["sessionId": "local_example", "cliSessionId": "cli-session", "cwd": "/outside/workspace", "createdAt": 1, "lastActivityAt": 2, "userSelectedFolders": ["/outside/workspace"]]
        let source = try write(home, relative, String(decoding: JSONSerialization.data(withJSONObject: metadata), as: UTF8.self))
        let unit = String(relative.dropLast(5))
        _ = try write(home, unit + "/transcripts/cli-session.jsonl")
        _ = try write(home, unit + "/outputs/file", "output")
        let link = home.appendingPathComponent(unit + "/external-link")
        XCTAssertEqual(symlink("/outside/never-read", link.path), 0)
        let archive = root.appendingPathComponent("desktop.zip")
        _ = try NativeSessionBackup.create(source: source, home: home, destination: archive, includeSensitive: true)
        let manifest = try verify(archive)
        XCTAssertEqual(manifest.files.count, 4)
        XCTAssertEqual(manifest.files.filter(\.isLink).count, 1)
        let reference = try python(home, "print(json.dumps(m.verify_session_backup(Path(sys.argv[3]))))", extra: [archive.path])
        XCTAssertEqual(reference["provider"] as? String, "Claude Desktop")
        let restored = root.appendingPathComponent("restored")
        _ = try NativeSessionBackup.restore(archive: archive, destination: restored, home: home)
        XCTAssertEqual(try NativeFileTree.link(restored.appendingPathComponent(unit + "/external-link")), "/outside/never-read")
    }
    func testSensitiveAcknowledgementAndNoOverwriteAreEnforced() throws {
        let root = try temporary(), home = root.appendingPathComponent("home")
        let source = try write(home, ".codex/sessions/session.jsonl"), archive = root.appendingPathComponent("backup.zip")
        XCTAssertThrowsError(try NativeSessionBackup.create(source: source, home: home, destination: archive, includeSensitive: false))
        _ = try NativeSessionBackup.create(source: source, home: home, destination: archive, includeSensitive: true)
        let original = try Data(contentsOf: archive)
        XCTAssertThrowsError(try NativeSessionBackup.create(source: source, home: home, destination: archive, includeSensitive: true))
        XCTAssertEqual(try Data(contentsOf: archive), original)
        let destination = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = try write(destination, "keep.txt", "keep")
        XCTAssertThrowsError(try NativeSessionBackup.restore(archive: archive, destination: destination, home: home))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("keep.txt")), "keep")
    }
    func testSourceSymlinksHardlinksAndSpecialFilesAreRejected() throws {
        let root = try temporary(), home = root.appendingPathComponent("home")
        let source = try write(home, ".codex/sessions/session.jsonl"), archive = root.appendingPathComponent("backup.zip")
        let hard = root.appendingPathComponent("hardlink")
        XCTAssertEqual(link(source.path, hard.path), 0)
        XCTAssertThrowsError(try NativeSessionBackup.create(source: source, home: home, destination: archive, includeSensitive: true))
        try FileManager.default.removeItem(at: hard)
        try FileManager.default.removeItem(at: source)
        let outside = try write(root, "outside", "do not read")
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
        XCTAssertThrowsError(try NativeSessionBackup.create(source: source, home: home, destination: archive, includeSensitive: true))
        try FileManager.default.removeItem(at: source); XCTAssertEqual(mkfifo(source.path, 0o600), 0)
        XCTAssertThrowsError(try NativeSessionBackup.create(source: source, home: home, destination: archive, includeSensitive: true))
        XCTAssertFalse(NativeFileTree.exists(archive))
    }
    func testRestoreRejectsLiveStoresIncludingCaseAndSymlinkAliases() throws {
        let root = try temporary(), home = root.appendingPathComponent("home")
        let source = try write(home, ".codex/sessions/session.jsonl"), archive = root.appendingPathComponent("backup.zip")
        _ = try NativeSessionBackup.create(source: source, home: home, destination: archive, includeSensitive: true)
        XCTAssertThrowsError(try NativeSessionBackup.restore(archive: archive, destination: home.appendingPathComponent(".CODEX/copy"), home: home))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: home.appendingPathComponent(".codex"))
        XCTAssertThrowsError(try NativeSessionBackup.restore(archive: archive, destination: alias.appendingPathComponent("copy"), home: home))
    }
    func testTraversalExtraPayloadAndCorruptChecksumsAreRejected() throws {
        let root = try temporary(), home = root.appendingPathComponent("home")
        let source = try write(home, ".codex/sessions/session.jsonl"), archive = root.appendingPathComponent("backup.zip")
        _ = try NativeSessionBackup.create(source: source, home: home, destination: archive, includeSensitive: true)
        let zip = try Archive(url: archive, accessMode: .update), bytes = Data("outside".utf8)
        try zip.addEntry(with: "payload/../outside", type: .file, uncompressedSize: Int64(bytes.count)) { offset, count in bytes.subdata(in: Int(offset)..<Int(offset) + count) }
        XCTAssertThrowsError(try verify(archive))
        XCTAssertFalse(NativeFileTree.exists(root.appendingPathComponent("outside")))
    }
    func testRollbackRemovesOnlyOwnedFilesAndRetryRecoversJournal() throws {
        let root = try temporary(), parent = root.appendingPathComponent("outputs")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        do {
            let transaction = try NativeRestoreTransaction(parent: parent, name: "restore")
            _ = try transaction.directory(".codex/sessions", create: true)
            // Dropping descriptors models an interrupted worker, without running rollback.
        }
        XCTAssertEqual(try NativeRestoreTransaction.recover(parent: parent, name: "restore"), 1)
        XCTAssertFalse(NativeFileTree.exists(parent.appendingPathComponent("restore")))
        let next = try NativeRestoreTransaction(parent: parent, name: "restore")
        next.rollback()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }
    func testDigestMismatchAndHiddenEncryptedTailFailBeforeRestore() throws {
        let root = try temporary(), home = root.appendingPathComponent("home")
        let source = try write(home, ".codex/sessions/session.jsonl"), archive = root.appendingPathComponent("backup.zip")
        _ = try NativeSessionBackup.create(source: source, home: home, destination: archive, includeSensitive: true)
        let corrupt = root.appendingPathComponent("corrupt.zip")
        _ = try python(home, "import zipfile; z=zipfile.ZipFile(sys.argv[3]); items=[(i.filename,z.read(i)) for i in z.infolist()]; z.close(); out=zipfile.ZipFile(sys.argv[4],'w'); [out.writestr(n, b'X'+d[1:] if n.startswith('payload/') else d) for n,d in items]; out.close(); print('{}')", extra: [archive.path, corrupt.path])
        XCTAssertThrowsError(try verify(corrupt), "valid ZIP CRC must not bypass the manifest SHA-256")
        let hidden = root.appendingPathComponent("encrypted-tail.zip")
        try FileManager.default.copyItem(at: archive, to: hidden)
        do {
            let zip = try Archive(url: hidden, accessMode: .update)
            try zip.addEntry(with: "hidden", type: .file, uncompressedSize: Int64(1)) { _, _ in Data([1]) }
        }
        var bytes = try Data(contentsOf: hidden), changed = 0
        for index in 0..<(bytes.count - 51) {
            let signature = Array(bytes[index..<index + 4])
            let local = signature == [0x50, 0x4b, 0x03, 0x04], central = signature == [0x50, 0x4b, 0x01, 0x02]
            if local || central {
                let nameOffset = index + (local ? 30 : 46)
                if Array(bytes[nameOffset..<nameOffset + 6]) == Array("hidden".utf8) {
                    bytes[index + (local ? 6 : 8)] |= 1; changed += 1
                }
            }
        }
        XCTAssertEqual(changed, 2)
        try bytes.write(to: hidden)
        XCTAssertThrowsError(try verify(hidden), "unsupported tail entries must not disappear from the verified directory count")
        let destination = root.appendingPathComponent("must-not-exist")
        for invalid in [corrupt, hidden] {
            XCTAssertThrowsError(try NativeSessionBackup.restore(archive: invalid, destination: destination, home: home))
            XCTAssertFalse(NativeFileTree.exists(destination))
        }
    }
    func testRecoveryNeverDeletesUnrecordedData() throws {
        let root = try temporary()
        var guardPath: URL!
        do {
            let transaction = try NativeRestoreTransaction(parent: root, name: "restore")
            guardPath = root.appendingPathComponent(transaction.guardName)
            _ = try write(guardPath.appendingPathComponent(".restore-root"), "foreign", "preserve")
        }
        XCTAssertThrowsError(try NativeRestoreTransaction.recover(parent: root, name: "restore"))
        XCTAssertEqual(try String(contentsOf: guardPath.appendingPathComponent(".restore-root/foreign")), "preserve")
    }
    func testTerminatedNativeWorkerRollsBackUnpublishedRestore() throws {
        let root = try temporary(), home = root.appendingPathComponent("home")
        let source = try write(home, ".claude/projects/project/session.jsonl")
        for index in 0..<600 {
            _ = try write(home, ".claude/projects/project/session/tool-results/\(index).txt", "result \(index)")
        }
        let archive = root.appendingPathComponent("backup.zip"), destination = root.appendingPathComponent("restored")
        _ = try NativeSessionBackup.create(source: source, home: home, destination: archive, includeSensitive: true)
        let request = root.appendingPathComponent("request.json")
        try JSONSerialization.data(withJSONObject: ["arguments": ["backup-restore", archive.path, "--out", destination.path, "--home", home.path]]).write(to: request)
        let process = Process(), output = Pipe()
        process.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Modore")
        process.arguments = [NativeOperationService.argument, "session-backup", request.path]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }
        var writing = false
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            let ledger = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix(".modore-native-restore-v1-") }
            if let ledger, let journal = try? Data(contentsOf: ledger.appendingPathComponent("journal.jsonl")),
               journal.filter({ $0 == 10 }).count > 10 {
                writing = true; kill(process.processIdentifier, SIGTERM); break
            }
            usleep(1_000)
        }
        XCTAssertTrue(writing, "worker must be cancelled during extraction")
        let stopped = ProcessInfo.processInfo.systemUptime + 15
        while process.isRunning && ProcessInfo.processInfo.systemUptime < stopped { usleep(10_000) }
        XCTAssertFalse(process.isRunning, "cancelled worker must drain rollback within its deadline")
        guard !process.isRunning else { return }
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 1)
        XCTAssertFalse(NativeFileTree.exists(destination))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".modore-native-restore-v1-") })
        XCTAssertEqual(try verify(archive).files.count, 601)
        XCTAssertEqual(try String(contentsOf: source), "{\"type\":\"user\",\"message\":{\"content\":\"original text\"}}\n")
    }
}
