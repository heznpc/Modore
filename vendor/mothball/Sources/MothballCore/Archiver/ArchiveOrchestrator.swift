import Darwin
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
        /// The session gate refused. Listed first because it is the only
        /// error here that is a policy decision rather than a failure:
        /// nothing went wrong, the caller just has not done enough yet.
        case continuityRefused(ContinuityGate.Refusal)
        /// The world moved between the assessment and the archive. Not a
        /// failure of any step -- every step did its job, on a picture
        /// that stopped being true partway through.
        case revalidationFailed(reason: String)
        case sessionCompressionFailed(stderr: String, exitCode: Int32)
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
        case sealingSessions(count: Int, bytes: Int64)
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
        /// The sibling `.sessions.tar.zst`, when this workspace had
        /// sessions to seal.
        public let sessionArchive: URL?
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
    /// - Parameter continuity: what a binder found out about this
    ///   workspace's agent sessions. There is deliberately no default.
    ///   A default would be `.notAssessed` — which blocks, turning a
    ///   compile-time obligation into a runtime surprise — or something
    ///   permissive, which silently reintroduces the exact hazard this
    ///   parameter exists to close. Every call site states its answer.
    /// - Parameter revalidate: run after the gate and before any bytes
    ///   are written, to confirm the picture the assessment was built
    ///   from still holds. Sealing hundreds of megabytes takes long
    ///   enough for an agent to write a new session or for the working
    ///   tree to change, and every check upstream of this ran on the
    ///   older world. Throwing here costs a wasted seal; not checking
    ///   costs the thing the seal was protecting.
    public func archive(
        _ repo: RepoInfo,
        continuity: ContinuityAssessment,
        revalidate: (@Sendable () async throws -> Void)? = nil,
        progress: (@Sendable (Step) async -> Void)? = nil
    ) async throws -> ArchiveResult {
        let env = configuration
        await progress?(.starting(repo: repo.path))

        // Gate first, before any work: a refusal must cost nothing and
        // must not leave a half-built archive behind to explain.
        if case .block(let refusal) = ContinuityGate.evaluate(continuity) {
            throw ArchiveError.continuityRefused(refusal)
        }

        // Before validation and before the first byte: a refusal here
        // must cost nothing but the seal that already happened.
        if let revalidate {
            do {
                try await revalidate()
            } catch let error as ArchiveError {
                throw error
            } catch {
                throw ArchiveError.revalidationFailed(reason: String(describing: error))
            }
        }

        try Self.validateSource(repo.path, archiveDirectory: env.archiveDirectory)
        try Self.validateArchiveDirectory(env.archiveDirectory)

        let plan = ArchivePlan(repo: repo, archiveDirectory: env.archiveDirectory)

        if FileManager.default.fileExists(atPath: plan.archiveFinal.path) ||
           FileManager.default.fileExists(atPath: plan.manifestFinal.path) ||
           FileManager.default.fileExists(atPath: plan.sessionsFinal.path) {
            throw ArchiveError.archiveAlreadyExists(plan.archiveFinal)
        }

        // Ensure no leftover tmp from a previous crashed run blocks us.
        Self.removeIfExists(plan.archiveTmp)
        Self.removeIfExists(plan.manifestTmp)
        Self.removeIfExists(plan.sessionsTmp)

        // Defer cleanup of tmp files. If a rename promoted a tmp to
        // final, the path no longer exists at the .tmp location and
        // removeIfExists is a no-op.
        defer {
            Self.removeIfExists(plan.archiveTmp)
            Self.removeIfExists(plan.manifestTmp)
            Self.removeIfExists(plan.sessionsTmp)
        }

        // 1. Sessions, if any were sealed. Done before the workspace tar
        //    so a failure here costs the cheaper of the two compressions.
        //    The staging tree is the sealer's copy; the digests already in
        //    `bundle` describe these exact bytes, which is why the copy
        //    had to happen before the hash rather than after.
        var sealedBundle: ContinuityBundle?
        if case .sealed(let bundle, _) = continuity, !bundle.sessions.isEmpty {
            sealedBundle = bundle
            await progress?(.sealingSessions(count: bundle.sessions.count, bytes: bundle.totalBytes))
            try await runSessionTarCreate(plan: plan, bundle: bundle, env: env)
        }

        // 2. Compress the workspace.
        await progress?(.compressing(estimatedSourceBytes: repo.sizeBytes))
        try await runTarCreate(plan: plan, env: env)

        // 3. Verify the archives are structurally readable. Catches
        //    truncation or zstd corruption before we trust them enough to
        //    delete the original.
        await progress?(.verifying)
        try await runTarVerify(archive: plan.archiveTmp, env: env)
        if sealedBundle != nil {
            try await runTarVerify(archive: plan.sessionsTmp, env: env)
        }

        // 4. Manifest.
        await progress?(.writingManifest)
        let archiveBytes = Self.fileSize(at: plan.archiveTmp) ?? 0
        let manifest = makeManifest(
            repo: repo,
            archiveBytes: archiveBytes,
            appVersion: env.appVersion,
            archivedAt: Date(),
            continuity: continuity,
            sessionArchiveName: sealedBundle == nil ? nil : plan.sessionsFinal.lastPathComponent
        )
        do {
            let data = try ArchiveManifest.encoder().encode(manifest)
            try data.write(to: plan.manifestTmp, options: [.atomic])
        } catch {
            throw ArchiveError.manifestWriteFailed(underlying: error)
        }

        // 5. Promote to final names. Same-directory rename on the same
        //    filesystem is effectively atomic. The manifest goes last and
        //    a failure rolls the others back, because the manifest is what
        //    makes the other files identifiable — an orphan `.tar.zst`
        //    with no sidecar is exactly the opaque blob this whole design
        //    exists to avoid producing.
        var promoted: [URL] = []
        func rollBackPromoted() { for url in promoted { Self.removeIfExists(url) } }

        if sealedBundle != nil {
            do {
                try FileManager.default.moveItem(at: plan.sessionsTmp, to: plan.sessionsFinal)
                promoted.append(plan.sessionsFinal)
            } catch {
                throw ArchiveError.finalRenameFailed(underlying: error)
            }
        }
        do {
            try FileManager.default.moveItem(at: plan.archiveTmp, to: plan.archiveFinal)
            promoted.append(plan.archiveFinal)
        } catch {
            rollBackPromoted()
            throw ArchiveError.finalRenameFailed(underlying: error)
        }
        do {
            try FileManager.default.moveItem(at: plan.manifestTmp, to: plan.manifestFinal)
        } catch {
            // Roll back: delete the now-orphaned archives. The original is
            // untouched, so the user loses nothing.
            rollBackPromoted()
            throw ArchiveError.finalRenameFailed(underlying: error)
        }

        // 6. Trash the original. If THIS fails, we still have a valid
        //    archive + manifest — leave the original in place and let
        //    the caller decide. Don't roll back the archive.
        await progress?(.movingOriginalToTrash)
        let trashedURL: URL?
        do {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: repo.path, resultingItemURL: &resulting)
            trashedURL = resulting as URL?
        } catch {
            throw ArchiveError.trashFailed(repo.path, underlying: error)
        }

        await progress?(.completed(
            archive: plan.archiveFinal,
            manifest: plan.manifestFinal,
            archiveBytes: archiveBytes
        ))

        return ArchiveResult(
            archive: plan.archiveFinal,
            manifest: plan.manifestFinal,
            archiveBytes: archiveBytes,
            originalBytes: repo.sizeBytes,
            trashedItemURL: trashedURL,
            sessionArchive: sealedBundle == nil ? nil : plan.sessionsFinal
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

    /// Tars the sealer's staging tree. `-C stagingRoot` with the single
    /// entry `sessions` keeps this archive to one top-level directory,
    /// the same shape the workspace archive has, so one extraction check
    /// covers both.
    private func runSessionTarCreate(
        plan: ArchivePlan,
        bundle: ContinuityBundle,
        env: Configuration
    ) async throws {
        let result = try await ProcessRunner.run(
            executable: env.tarExecutable,
            arguments: [
                "--zstd",
                "--options", "zstd:compression-level=\(env.zstdLevel)",
                "-cf", plan.sessionsTmp.path,
                "-C", bundle.stagingRoot.path,
                "--",
                ContinuitySealer.rootDirectoryName,
            ],
            timeout: env.compressionTimeout,
            wrapping: ArchiveError.process
        )
        guard result.isSuccess else {
            throw ArchiveError.sessionCompressionFailed(stderr: result.stderr, exitCode: result.exitCode)
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
        archivedAt: Date,
        continuity: ContinuityAssessment,
        sessionArchiveName: String?
    ) -> ArchiveManifest {
        return ArchiveManifest(
            schemaVersion: ArchiveManifest.currentSchemaVersion,
            archivedAt: archivedAt,
            archivedBy: appVersion,
            originalPath: repo.path.path,
            sizeBytesBefore: repo.sizeBytes,
            sizeBytesArchive: archiveBytes,
            git: ArchiveManifest.Git(from: repo.git),
            restoreHint: repo.git.originURL.map { "git clone \($0)" },
            // The scanner sees a repo where it is now. Earlier locations
            // come from session bindings, which this type does not have —
            // so a single-entry list, honestly, rather than a fabricated
            // history.
            historicalPaths: [repo.path.path],
            continuity: ArchiveManifest.Continuity(
                assessment: continuity.manifestTag,
                sessionArchive: sessionArchiveName,
                sessions: continuity.sealedSessions,
                // Nothing writes an override any more; the field stays so
                // manifests from the standalone era still decode.
                overrideReason: nil
            )
        )
    }

    static func fileSize(at url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    static func removeIfExists(_ url: URL) {
        // Every archive-plan temporary/final artifact is a file. `unlink`
        // makes cleanup idempotent without allowing a secondary Foundation
        // remove error to replace the archive operation's real error while a
        // throwing async scope is unwinding.
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            _ = Darwin.unlink(path)
        }
    }
}
