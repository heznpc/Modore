import Foundation

public struct ArchiveOrchestrator: Sendable {

    public struct Configuration: Sendable {
        public let archiveDirectory: URL
        public let tarExecutable: URL
        public let zstdLevel: Int            // 1 (fast) – 19 (best); 3 is the tar default
        public let compressionTimeout: Duration
        public let verificationTimeout: Duration
        public let appVersion: String

        public init(
            archiveDirectory: URL,
            tarExecutable: URL = URL(fileURLWithPath: "/usr/bin/tar"),
            zstdLevel: Int = 3,
            compressionTimeout: Duration = .seconds(30 * 60),
            verificationTimeout: Duration = .seconds(5 * 60),
            appVersion: String = "Mothball/0.1"
        ) {
            self.archiveDirectory = archiveDirectory
            self.tarExecutable = tarExecutable
            self.zstdLevel = zstdLevel
            self.compressionTimeout = compressionTimeout
            self.verificationTimeout = verificationTimeout
            self.appVersion = appVersion
        }
    }

    public enum ArchiveError: Error, Sendable {
        case archiveDirectoryUnusable(URL, underlying: Error?)
        case sourcePathRefused(URL, reason: String)
        case archiveAlreadyExists(URL)
        case compressionFailed(stderr: String, exitCode: Int32)
        case verificationFailed(stderr: String, exitCode: Int32)
        case manifestWriteFailed(underlying: Error)
        case finalRenameFailed(underlying: Error)
        case trashFailed(URL, underlying: Error)
        case process(ProcessError)
    }

    public enum Step: Sendable {
        case starting(repo: URL)
        case compressing(estimatedSourceBytes: Int64)
        case verifying
        case writingManifest
        case movingOriginalToTrash
        case completed(archive: URL, manifest: URL, archiveBytes: Int64)
    }

    public struct ArchiveResult: Sendable, Equatable {
        public let archive: URL
        public let manifest: URL
        public let archiveBytes: Int64
        public let originalBytes: Int64
        public let trashedItemURL: URL?
    }

    public let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Archives a single repo. Caller MUST serialize calls — this type
    /// is `Sendable` but does not internally guard against concurrent
    /// archives of overlapping paths.
    ///
    /// On failure, partial files (`.tmp`) are always cleaned up. The
    /// original is only moved to trash after the archive AND manifest
    /// are both at their final paths and verified.
    public func archive(
        _ repo: RepoInfo,
        progress: (@Sendable (Step) -> Void)? = nil
    ) async throws -> ArchiveResult {
        let env = configuration
        progress?(.starting(repo: repo.path))

        try Self.validateSource(repo.path, archiveDirectory: env.archiveDirectory)
        try Self.validateArchiveDirectory(env.archiveDirectory)

        let plan = ArchivePlan(repo: repo, archiveDirectory: env.archiveDirectory)

        if FileManager.default.fileExists(atPath: plan.archiveFinal.path) ||
           FileManager.default.fileExists(atPath: plan.manifestFinal.path) {
            throw ArchiveError.archiveAlreadyExists(plan.archiveFinal)
        }

        // Ensure no leftover tmp from a previous crashed run blocks us.
        Self.removeIfExists(plan.archiveTmp)
        Self.removeIfExists(plan.manifestTmp)

        // Defer cleanup of tmp files. If a rename promoted a tmp to
        // final, the path no longer exists at the .tmp location and
        // removeIfExists is a no-op.
        defer {
            Self.removeIfExists(plan.archiveTmp)
            Self.removeIfExists(plan.manifestTmp)
        }

        // 1. Compress.
        progress?(.compressing(estimatedSourceBytes: repo.sizeBytes))
        try await runTarCreate(plan: plan, env: env)

        // 2. Verify the archive is structurally readable. Catches truncation
        //    or zstd corruption before we trust it enough to delete the
        //    original.
        progress?(.verifying)
        try await runTarVerify(archive: plan.archiveTmp, env: env)

        // 3. Manifest.
        progress?(.writingManifest)
        let archiveBytes = Self.fileSize(at: plan.archiveTmp) ?? 0
        let manifest = makeManifest(
            repo: repo,
            archiveBytes: archiveBytes,
            appVersion: env.appVersion,
            archivedAt: Date()
        )
        do {
            let data = try ArchiveManifest.encoder().encode(manifest)
            try data.write(to: plan.manifestTmp, options: [.atomic])
        } catch {
            throw ArchiveError.manifestWriteFailed(underlying: error)
        }

        // 4. Promote both to final names. Same-directory rename on the
        //    same filesystem is effectively atomic. Manifest goes second —
        //    if it fails, we roll the archive back so we never have an
        //    orphan archive without identifying metadata.
        do {
            try FileManager.default.moveItem(at: plan.archiveTmp, to: plan.archiveFinal)
        } catch {
            throw ArchiveError.finalRenameFailed(underlying: error)
        }
        do {
            try FileManager.default.moveItem(at: plan.manifestTmp, to: plan.manifestFinal)
        } catch {
            // Roll back: delete the now-orphaned archive. Original is
            // untouched, so the user loses nothing.
            Self.removeIfExists(plan.archiveFinal)
            throw ArchiveError.finalRenameFailed(underlying: error)
        }

        // 5. Trash the original. If THIS fails, we still have a valid
        //    archive + manifest — leave the original in place and let
        //    the caller decide. Don't roll back the archive.
        progress?(.movingOriginalToTrash)
        let trashedURL: URL?
        do {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: repo.path, resultingItemURL: &resulting)
            trashedURL = resulting as URL?
        } catch {
            throw ArchiveError.trashFailed(repo.path, underlying: error)
        }

        progress?(.completed(
            archive: plan.archiveFinal,
            manifest: plan.manifestFinal,
            archiveBytes: archiveBytes
        ))

        return ArchiveResult(
            archive: plan.archiveFinal,
            manifest: plan.manifestFinal,
            archiveBytes: archiveBytes,
            originalBytes: repo.sizeBytes,
            trashedItemURL: trashedURL
        )
    }

    // MARK: - Validation

    static func validateSource(_ source: URL, archiveDirectory: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
            throw ArchiveError.sourcePathRefused(source, reason: "경로가 존재하지 않거나 디렉토리가 아님")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let resolved = source.standardizedFileURL.path
        if resolved == "/" || resolved == home {
            throw ArchiveError.sourcePathRefused(source, reason: "홈 또는 루트 디렉토리는 아카이브할 수 없음")
        }
        let archiveResolved = archiveDirectory.standardizedFileURL.path
        if resolved == archiveResolved || archiveResolved.hasPrefix(resolved + "/") {
            throw ArchiveError.sourcePathRefused(source, reason: "아카이브 저장 위치가 원본 안에 있음 (자기 참조)")
        }
        // Reverse containment: the source must not live inside the archive
        // directory either. Otherwise tar would recursively read a tree it
        // is simultaneously writing into — at best a libarchive
        // "file changed as we read it" error, at worst unbounded growth as
        // the in-progress .tar.zst.tmp is itself included in the archive.
        if resolved.hasPrefix(archiveResolved + "/") {
            throw ArchiveError.sourcePathRefused(source, reason: "원본이 아카이브 저장 위치 안에 있음 (자기 참조)")
        }
    }

    static func validateArchiveDirectory(_ dir: URL) throws {
        // createDirectory(withIntermediateDirectories: true) is a no-op
        // for an existing directory, so an upfront `fileExists` check
        // adds a stat for no benefit (and a TOCTOU window besides).
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw ArchiveError.archiveDirectoryUnusable(dir, underlying: error)
        }
        if !fm.isWritableFile(atPath: dir.path) {
            throw ArchiveError.archiveDirectoryUnusable(dir, underlying: nil)
        }
    }

    // MARK: - tar invocation

    private func runTarCreate(plan: ArchivePlan, env: Configuration) async throws {
        // Run with -C parent so the archive contains the basename only,
        // not the full absolute path. This makes archives portable and
        // restores cleanly when extracted into any directory.
        //
        // The `--` before the basename is load-bearing: without it, a repo
        // literally named `--exclude` / `--newer` / `--help` (extracted
        // from a tarball, scratch dir, etc.) is parsed by tar as a flag,
        // not a path. macOS bsdtar then either fails to create the archive
        // at all (verified PoC) or silently skips files in it. Argv-array
        // calling alone does not defend against flag-shaped filenames.
        let result = try await ProcessRunner.run(
            executable: env.tarExecutable,
            arguments: [
                "--zstd",
                "--options", "zstd:compression-level=\(env.zstdLevel)",
                "-cf", plan.archiveTmp.path,
                "-C", plan.repoPath.deletingLastPathComponent().path,
                "--",
                plan.repoPath.lastPathComponent,
            ],
            timeout: env.compressionTimeout,
            wrapping: ArchiveError.process
        )
        guard result.isSuccess else {
            throw ArchiveError.compressionFailed(stderr: result.stderr, exitCode: result.exitCode)
        }
    }

    private func runTarVerify(archive: URL, env: Configuration) async throws {
        let result = try await ProcessRunner.run(
            executable: env.tarExecutable,
            arguments: ["--zstd", "-tf", archive.path],
            timeout: env.verificationTimeout,
            wrapping: ArchiveError.process
        )
        guard result.isSuccess else {
            throw ArchiveError.verificationFailed(stderr: result.stderr, exitCode: result.exitCode)
        }
    }

    // MARK: - Helpers

    private func makeManifest(
        repo: RepoInfo,
        archiveBytes: Int64,
        appVersion: String,
        archivedAt: Date
    ) -> ArchiveManifest {
        ArchiveManifest(
            schemaVersion: ArchiveManifest.currentSchemaVersion,
            archivedAt: archivedAt,
            archivedBy: appVersion,
            originalPath: repo.path.path,
            sizeBytesBefore: repo.sizeBytes,
            sizeBytesArchive: archiveBytes,
            git: ArchiveManifest.Git(from: repo.git),
            restoreHint: repo.git.originURL.map { "git clone \($0)" }
        )
    }

    static func fileSize(at url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    static func removeIfExists(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// All path planning collected in one place so it's easy to inspect
/// and unit-test independently of the orchestrator.
struct ArchivePlan {
    let repoPath: URL
    let archiveTmp: URL
    let archiveFinal: URL
    let manifestTmp: URL
    let manifestFinal: URL

    init(repo: RepoInfo, archiveDirectory: URL, now: Date = Date()) {
        self.repoPath = repo.path
        let stamp = ArchivePlan.timestamp(now)
        let base = "\(repo.path.lastPathComponent)_\(stamp)"
        self.archiveFinal   = archiveDirectory.appending(path: "\(base).tar.zst")
        self.manifestFinal  = archiveDirectory.appending(path: "\(base).json")
        self.archiveTmp     = archiveDirectory.appending(path: "\(base).tar.zst.tmp")
        self.manifestTmp    = archiveDirectory.appending(path: "\(base).json.tmp")
    }

    private static func timestamp(_ date: Date) -> String {
        // Filesystem-safe: no colons, no spaces. Sortable.
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withYear, .withMonth, .withDay, .withDashSeparatorInDate,
                           .withTime, .withColonSeparatorInTime]
        let raw = f.string(from: date)
        return raw.replacingOccurrences(of: ":", with: "-")
    }
}
