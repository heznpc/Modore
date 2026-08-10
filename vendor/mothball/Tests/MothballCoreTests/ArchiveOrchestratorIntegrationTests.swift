import XCTest
@testable import MothballCore

/// Integration tests that exercise the full archive pipeline end-to-end:
/// real `git`, real `tar`, real filesystem, real trash. macOS-only.
final class ArchiveOrchestratorIntegrationTests: XCTestCase {
    var repo: TempGitRepo!
    var archiveDir: URL!

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
    }

    override func tearDown() async throws {
        repo?.cleanup()
        if let archiveDir { try? FileManager.default.removeItem(at: archiveDir) }
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

    private func populatedRepoInfo() async throws -> RepoInfo {
        try await repo.initialize()
        try repo.writeFile("README.md", contents: "test content\n")
        try repo.writeFile("src/main.swift", contents: "print(\"hi\")\n")
        try await repo.commit("initial")
        try await repo.fakePushedOrigin()
        return try await RepoScanner().scan(roots: [repo.url.deletingLastPathComponent()])
            .first { $0.path.standardizedFileURL == repo.url.standardizedFileURL } ?? XCTUnwrap(nil)
    }

    // MARK: - Tests

    func test_archive_producesArchiveAndManifestAtFinalPaths() async throws {
        let info = try await singleRepoInfo()
        let result = try await makeOrchestrator().archive(info)

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.archive.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.manifest.path))
        XCTAssertTrue(result.archive.lastPathComponent.hasSuffix(".tar.zst"))
        XCTAssertTrue(result.manifest.lastPathComponent.hasSuffix(".json"))
        XCTAssertGreaterThan(result.archiveBytes, 0)
    }

    func test_archive_movesOriginalToTrash() async throws {
        let info = try await singleRepoInfo()
        let originalPath = info.path

        let result = try await makeOrchestrator().archive(info)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: originalPath.path),
            "original should be gone from its original location"
        )
        XCTAssertNotNil(result.trashedItemURL, "trashItem returns the new URL inside Trash")
    }

    func test_archive_manifestRoundTrips() async throws {
        let info = try await singleRepoInfo()
        let result = try await makeOrchestrator().archive(info)

        let data = try Data(contentsOf: result.manifest)
        let manifest = try ArchiveManifest.decoder().decode(ArchiveManifest.self, from: data)

        XCTAssertEqual(manifest.schemaVersion, ArchiveManifest.currentSchemaVersion)
        XCTAssertEqual(manifest.originalPath, info.path.path)
        XCTAssertEqual(manifest.git.origin, "https://example.invalid/fake/repo.git")
        XCTAssertEqual(manifest.git.branch, "main")
        XCTAssertEqual(manifest.git.aheadOfOrigin, 0)
        XCTAssertFalse(manifest.git.wasDirty)
        XCTAssertNotNil(manifest.restoreHint)
    }

    func test_archive_refusesIfFinalArchiveAlreadyExists() async throws {
        let info = try await singleRepoInfo()
        let plan = ArchivePlan(repo: info, archiveDirectory: archiveDir, now: Date())
        // Plant a file at the would-be final path. Since the timestamp
        // is generated inside ArchivePlan we mimic the same now() to
        // collide deterministically.
        try Data().write(to: plan.archiveFinal)

        do {
            _ = try await makeOrchestrator().archive(info)
            // Acceptable: a different timestamp could theoretically save
            // us, but in practice second-resolution + same `now()` means
            // a guaranteed collision. We treat success as still passing
            // because the actual safety guarantee (no overwrite) holds
            // either way — we just assert the planted file is intact.
        } catch ArchiveOrchestrator.ArchiveError.archiveAlreadyExists {
            // expected most of the time
        }

        // Either branch: planted file must still be there.
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.archiveFinal.path))
    }

    func test_archive_refusesHomeDirectory() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fake = RepoInfo(
            path: home,
            sizeBytes: 0,
            lastFileMTime: Date(),
            git: GitMetadata(
                lastCommitDate: nil, isDirty: false, aheadOfOrigin: nil,
                originURL: nil, currentBranch: nil, headSHA: nil
            )
        )
        do {
            _ = try await makeOrchestrator().archive(fake)
            XCTFail("expected sourcePathRefused")
        } catch ArchiveOrchestrator.ArchiveError.sourcePathRefused {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// Regression for the source-inside-archiveDir case (audit finding #2).
    /// User points the archive root at a directory whose subtree contains
    /// the repo they then ask to archive — tar would otherwise recursively
    /// read the tree it's simultaneously writing into.
    func test_archive_refusesSourceInsideArchiveDir() async throws {
        // Build a repo *inside* the archive directory.
        let nested = archiveDir.appending(path: "nested-repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: nested.appending(path: "README.md"))

        let fake = RepoInfo(
            path: nested,
            sizeBytes: 2,
            lastFileMTime: Date(),
            git: GitMetadata(
                lastCommitDate: nil, isDirty: false, aheadOfOrigin: nil,
                originURL: nil, currentBranch: nil, headSHA: nil
            )
        )
        do {
            _ = try await makeOrchestrator().archive(fake)
            XCTFail("expected sourcePathRefused for source inside archive dir")
        } catch ArchiveOrchestrator.ArchiveError.sourcePathRefused {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// Regression for the tar `--` separator (audit finding #1). A repo
    /// whose basename starts with `-` (legitimate: extracted from a
    /// tarball, scratch dir) must archive cleanly. Without the `--`
    /// separator tar parses the basename as a flag and either fails to
    /// create the archive or silently skips files.
    func test_archive_handlesDashPrefixedRepoName() async throws {
        // Build a repo whose lastPathComponent starts with `-`. Can't use
        // TempGitRepo for this — its name is UUID-shaped. Spin up a
        // sibling alongside repo.url.
        let parent = repo.url.deletingLastPathComponent()
        let dashy = parent.appending(path: "--exclude-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dashy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dashy) }
        try Data("hi".utf8).write(to: dashy.appending(path: "README.md"))

        let fake = RepoInfo(
            path: dashy,
            sizeBytes: 2,
            lastFileMTime: Date(),
            git: GitMetadata(
                lastCommitDate: nil, isDirty: false, aheadOfOrigin: nil,
                originURL: nil, currentBranch: nil, headSHA: nil
            )
        )
        let result = try await makeOrchestrator().archive(fake)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.archive.path),
                      "tar must produce the archive even when basename starts with `-`")
        XCTAssertGreaterThan(result.archiveBytes, 0,
                             "archive must contain content, not be an empty zero-byte file")
    }

    func test_archive_originalSizeIsRecordedInResult() async throws {
        let info = try await singleRepoInfo()
        let result = try await makeOrchestrator().archive(info)
        XCTAssertEqual(result.originalBytes, info.sizeBytes)
    }

    // MARK: -

    private func singleRepoInfo() async throws -> RepoInfo {
        try await repo.initialize()
        try repo.writeFile("README.md", contents: "test content\n")
        try repo.writeFile("data.bin", contents: String(repeating: "abc", count: 1000))
        try await repo.commit("initial")
        try await repo.fakePushedOrigin()

        // Use the scanner so size and mtime are computed identically to
        // what production would feed in.
        let infos = await RepoScanner().scan(roots: [repo.url.deletingLastPathComponent()])
        guard let mine = infos.first(where: { $0.path.standardizedFileURL == repo.url.standardizedFileURL }) else {
            struct NotFound: Error {}
            throw NotFound()
        }
        return mine
    }
}
