import XCTest
import CryptoKit
@testable import MothballCore

/// End-to-end proof that archiving is reversible: a real git repo is
/// archived (original sent to Trash) and then restored into a fresh
/// destination, and the restored tree is asserted byte-for-byte identical
/// to the original — including `.git` internals — with git itself
/// confirming the restored repo resolves the same HEAD.
///
/// This is the test that gates the destructive tool: if the round-trip
/// here ever stops being exact, archiving has no business deleting
/// anything. Asserting "a directory appeared" would be worthless here, so
/// every assertion checks content or behavior, never mere existence.
final class RestoreRoundTripTests: XCTestCase {
    var repo: TempGitRepo!
    var archiveDir: URL!
    var restoreParent: URL!

    override func setUp() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/bin/git") &&
            FileManager.default.isExecutableFile(atPath: "/usr/bin/tar"),
            "git and tar both required at /usr/bin"
        )
        repo = try TempGitRepo()
        archiveDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MothballArchive-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        restoreParent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MothballRestore-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: restoreParent, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        repo?.cleanup()
        if let archiveDir { try? FileManager.default.removeItem(at: archiveDir) }
        if let restoreParent { try? FileManager.default.removeItem(at: restoreParent) }
    }

    // MARK: - The round-trip

    func test_archiveThenRestore_reproducesExactTreeIncludingGit() async throws {
        // A populated repo: a nested directory, a couple of text files, a
        // larger file to exercise real compression, and a real `.git` from
        // an actual commit.
        try await repo.initialize()
        try repo.writeFile("README.md", contents: "test content\n")
        try FileManager.default.createDirectory(
            at: repo.url.appending(path: "src"), withIntermediateDirectories: true
        )
        try repo.writeFile("src/main.swift", contents: "print(\"hi\")\n")
        try repo.writeFile("data.bin", contents: String(repeating: "abc123\n", count: 500))
        try await repo.commit("initial")
        try await repo.fakePushedOrigin()

        // Scan FIRST — `git status` during the scan can refresh `.git/index`,
        // so the ground-truth snapshot must be taken after it to match the
        // exact bytes that get archived.
        let infos = await RepoScanner().scan(roots: [repo.url.deletingLastPathComponent()])
        let info = try XCTUnwrap(
            infos.first { $0.path.standardizedFileURL == repo.url.standardizedFileURL }
        )
        let originalHead = try XCTUnwrap(info.git.headSHA, "committed repo must have a HEAD SHA")

        let originalMap = try Self.contentMap(of: repo.url)
        // The snapshot is only meaningful if it actually captured our files
        // AND git internals — otherwise the comparison below proves nothing.
        XCTAssertNotNil(originalMap["README.md"])
        XCTAssertNotNil(originalMap["src/main.swift"])
        XCTAssertTrue(
            originalMap.keys.contains { $0.hasPrefix(".git/") },
            "snapshot must include .git internals or the round-trip says nothing about git preservation"
        )

        // Archive: this moves the original to Trash.
        let archiveResult = try await makeOrchestrator().archive(info)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: repo.url.path),
            "precondition: archive must have removed the original from its location"
        )

        // Restore into a fresh, never-used destination.
        let dest = restoreParent.appending(path: "restored", directoryHint: .isDirectory)
        let restoreResult = try await makeRestorer().restore(
            manifestURL: archiveResult.manifest, to: dest
        )

        // 1. Landed exactly where asked, as a real directory.
        XCTAssertEqual(restoreResult.restoredPath.standardizedFileURL, dest.standardizedFileURL)
        XCTAssertTrue(Self.isDirectory(dest), "restored path must be a directory")
        XCTAssertTrue(
            Self.isDirectory(dest.appending(path: ".git")),
            ".git must be restored as a directory, not missing or a file"
        )

        // 2. Byte-for-byte identical tree, file-for-file, including .git.
        let restoredMap = try Self.contentMap(of: dest)
        XCTAssertEqual(
            restoredMap, originalMap,
            "restored tree must be byte-identical to the original (file set + contents + .git)"
        )

        // 3. Human-readable content sanity on a known file.
        let readme = try String(contentsOf: dest.appending(path: "README.md"), encoding: .utf8)
        XCTAssertEqual(readme, "test content\n")

        // 4. .git is FUNCTIONAL, not just byte-present: git resolves the
        //    same HEAD in the restored repo. (Run last so it cannot mutate
        //    the tree before the byte comparison above.)
        let head = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["rev-parse", "HEAD"],
            workingDirectory: dest,
            timeout: .seconds(10)
        )
        XCTAssertTrue(head.isSuccess, "git rev-parse failed in restored repo: \(head.stderr)")
        XCTAssertEqual(head.stdout.trimmingCharacters(in: .whitespacesAndNewlines), originalHead)

        // 5. The restorer reports the manifest it acted on.
        XCTAssertEqual(restoreResult.manifest.originalPath, info.path.path)
    }

    // MARK: - Safety rules (item 2): these must be behavior, not claims

    func test_restore_refusesNonEmptyDestination_withoutTouchingIt() async throws {
        let info = try await smallRepoInfo()
        let archiveResult = try await makeOrchestrator().archive(info)

        let dest = restoreParent.appending(path: "occupied", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data("do not clobber".utf8).write(to: dest.appending(path: "keep.txt"))

        do {
            _ = try await makeRestorer().restore(manifestURL: archiveResult.manifest, to: dest)
            XCTFail("expected destinationNotEmpty")
        } catch Restorer.RestoreError.destinationNotEmpty {
            // expected
        }
        // The pre-existing file must be untouched.
        let kept = try String(contentsOf: dest.appending(path: "keep.txt"), encoding: .utf8)
        XCTAssertEqual(kept, "do not clobber")
    }

    func test_restore_failsWhenSidecarHasNoArchive() async throws {
        // A valid manifest with no `.tar.zst` beside it.
        let manifest = ArchiveManifest(
            schemaVersion: ArchiveManifest.currentSchemaVersion,
            archivedAt: Date(),
            archivedBy: "Mothball/test",
            originalPath: restoreParent.appending(path: "whatever").path,
            sizeBytesBefore: 10,
            sizeBytesArchive: 5,
            git: .init(
                origin: nil, branch: nil, headSHA: nil,
                lastCommitDate: nil, aheadOfOrigin: nil, wasDirty: false
            ),
            restoreHint: nil
        )
        let manifestURL = archiveDir.appending(path: "orphan_2026-01-01T00-00-00.json")
        try ArchiveManifest.encoder().encode(manifest).write(to: manifestURL)

        do {
            _ = try await makeRestorer().restore(manifestURL: manifestURL)
            XCTFail("expected archiveMissing")
        } catch Restorer.RestoreError.archiveMissing {
            // expected
        }
    }

    func test_validateDestination_refusesHomeAndRoot() {
        XCTAssertThrowsError(
            try Restorer.validateDestination(FileManager.default.homeDirectoryForCurrentUser)
        ) { error in
            guard case Restorer.RestoreError.destinationRefused = error else {
                return XCTFail("home should be destinationRefused, got \(error)")
            }
        }
        XCTAssertThrowsError(try Restorer.validateDestination(URL(fileURLWithPath: "/"))) { error in
            guard case Restorer.RestoreError.destinationRefused = error else {
                return XCTFail("root should be destinationRefused, got \(error)")
            }
        }
    }

    func test_validateDestination_refusesNonEmptyDirectory() throws {
        let dir = restoreParent.appending(path: "full", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appending(path: "f"))
        XCTAssertThrowsError(try Restorer.validateDestination(dir)) { error in
            guard case Restorer.RestoreError.destinationNotEmpty = error else {
                return XCTFail("non-empty dir should be destinationNotEmpty, got \(error)")
            }
        }
    }

    func test_validateDestination_allowsNonexistentAndEmpty() throws {
        let fresh = restoreParent.appending(path: "fresh-\(UUID().uuidString)", directoryHint: .isDirectory)
        XCTAssertNoThrow(try Restorer.validateDestination(fresh))

        let empty = restoreParent.appending(path: "empty", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertNoThrow(try Restorer.validateDestination(empty))
    }

    func test_siblingArchiveURL_followsNamingContract() {
        let manifest = URL(fileURLWithPath: "/tmp/arc/myrepo_2026-01-01T00-00-00.json")
        let archive = Restorer.siblingArchiveURL(for: manifest)
        XCTAssertEqual(archive.path, "/tmp/arc/myrepo_2026-01-01T00-00-00.tar.zst")
    }

    // MARK: - Helpers

    private func makeOrchestrator(zstdLevel: Int = 1) -> ArchiveOrchestrator {
        ArchiveOrchestrator(configuration: .init(
            archiveDirectory: archiveDir,
            zstdLevel: zstdLevel,
            compressionTimeout: .seconds(60),
            verificationTimeout: .seconds(30)
        ))
    }

    private func makeRestorer() -> Restorer {
        Restorer(configuration: .init(extractionTimeout: .seconds(60)))
    }

    /// A minimal committed repo, scanned the same way production would.
    private func smallRepoInfo() async throws -> RepoInfo {
        try await repo.initialize()
        try repo.writeFile("README.md", contents: "small\n")
        try await repo.commit("initial")
        let infos = await RepoScanner().scan(roots: [repo.url.deletingLastPathComponent()])
        return try XCTUnwrap(
            infos.first { $0.path.standardizedFileURL == repo.url.standardizedFileURL }
        )
    }

    /// Maps every regular file under `root` to the hex SHA-256 of its
    /// contents, keyed by path relative to `root`. Hidden files (`.git`
    /// and everything under it) are included.
    private static func contentMap(of root: URL) throws -> [String: String] {
        var map: [String: String] = [:]
        let basePath = root.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return map }

        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(basePath + "/") else { continue }
            let relative = String(path.dropFirst(basePath.count + 1))
            let data = try Data(contentsOf: url)
            map[relative] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return map
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
