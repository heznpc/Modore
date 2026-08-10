import Foundation

/// Inverse of `ArchiveOrchestrator.archive`: takes a sidecar manifest,
/// finds the `.tar.zst` next to it, and reconstructs the original repo
/// directory at a chosen destination.
///
/// Restore is the safety net that makes archiving non-destructive *in
/// effect* — the original goes to Trash, but a verified round-trip back
/// out must exist or the tool has no business deleting anything. Two
/// invariants make this safe to run against a real home directory:
///
/// 1. **Never clobber.** A non-empty destination is refused outright, so
///    restoring "back to where it was" can't silently overwrite a fresh
///    clone or a partial recovery already sitting there.
///
/// 2. **All-or-nothing.** Extraction lands in a throwaway staging dir that
///    is a *sibling* of the destination (same filesystem). Only after the
///    structure is verified is the single extracted tree promoted into
///    place with one rename — atomic on the same volume. Any failure
///    removes the staging dir and leaves the destination untouched.
public struct Restorer: Sendable {

    public struct Configuration: Sendable {
        public let tarExecutable: URL
        public let extractionTimeout: Duration

        public init(
            tarExecutable: URL = URL(fileURLWithPath: "/usr/bin/tar"),
            extractionTimeout: Duration = .seconds(30 * 60)
        ) {
            self.tarExecutable = tarExecutable
            self.extractionTimeout = extractionTimeout
        }
    }

    public enum RestoreError: Error, Sendable {
        case manifestUnreadable(URL, underlying: Error?)
        case manifestDecodeFailed(URL, underlying: Error)
        case unsupportedSchema(found: Int, supported: Int)
        case archiveMissing(URL)
        case destinationRefused(URL, reason: String)
        case destinationNotEmpty(URL)
        case extractionFailed(stderr: String, exitCode: Int32)
        case verificationFailed(reason: String)
        case finalMoveFailed(underlying: Error)
        case process(ProcessError)
    }

    public enum Step: Sendable {
        case starting(manifest: URL)
        case extracting(archive: URL)
        case verifying
        case completed(restoredTo: URL, fileCount: Int)
    }

    public struct RestoreResult: Sendable, Equatable {
        /// The recreated repo root. Equal to the resolved destination.
        public let restoredPath: URL
        /// The `.tar.zst` the bytes came from.
        public let archive: URL
        /// The decoded sidecar that drove the restore.
        public let manifest: ArchiveManifest
    }

    public let configuration: Configuration

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    /// Restores the repo described by `manifestURL`.
    ///
    /// - Parameters:
    ///   - manifestURL: path to a `*.json` sidecar produced by `archive`.
    ///     The `*.tar.zst` is expected to sit beside it with the same base
    ///     name (the naming contract from `ArchivePlan`).
    ///   - destinationOverride: where to recreate the repo directory. When
    ///     `nil`, falls back to the manifest's `originalPath` (restore in
    ///     place). The destination is the repo root itself, *not* a
    ///     container to extract into.
    public func restore(
        manifestURL: URL,
        to destinationOverride: URL? = nil,
        progress: (@Sendable (Step) -> Void)? = nil
    ) async throws -> RestoreResult {
        progress?(.starting(manifest: manifestURL))

        // 1. Decode the sidecar. This is the source of truth for where the
        //    repo came from and what schema we're dealing with.
        let manifest = try Self.decodeManifest(at: manifestURL)
        guard manifest.schemaVersion == ArchiveManifest.currentSchemaVersion else {
            throw RestoreError.unsupportedSchema(
                found: manifest.schemaVersion,
                supported: ArchiveManifest.currentSchemaVersion
            )
        }

        // 2. Locate the archive next to the manifest by the naming contract:
        //    "<base>.json" ⇒ "<base>.tar.zst" in the same directory. We do
        //    not trust a path embedded in the manifest for this — the pair
        //    is identified by colocation, which survives the whole archive
        //    folder being moved or renamed.
        let archiveURL = Self.siblingArchiveURL(for: manifestURL)
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw RestoreError.archiveMissing(archiveURL)
        }

        // 3. Resolve and validate the destination.
        let dest = (destinationOverride ?? URL(fileURLWithPath: manifest.originalPath))
            .standardizedFileURL
        try Self.validateDestination(dest)

        // 4. Ensure the parent exists, then carve out a staging dir as a
        //    sibling of `dest` so the final promotion is a same-filesystem
        //    rename (atomic), not a cross-volume copy.
        let parent = dest.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw RestoreError.destinationRefused(
                parent, reason: "상위 디렉토리를 만들 수 없음: \(error.localizedDescription)"
            )
        }
        let staging = parent.appending(
            path: ".mothball-restore-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw RestoreError.destinationRefused(
                staging, reason: "임시 추출 디렉토리를 만들 수 없음: \(error.localizedDescription)"
            )
        }
        // Atomicity guard: whatever happens below, the half-extracted tree
        // never survives. A promoted tree no longer lives under `staging`,
        // so this is a no-op on the success path.
        defer { Self.removeIfExists(staging) }

        // 5. Extract into staging.
        progress?(.extracting(archive: archiveURL))
        try await runTarExtract(archive: archiveURL, into: staging)

        // 6. Verify the shape before trusting it: our archives contain
        //    exactly one top-level directory (the basename). Anything else
        //    means corruption or a tampered tarball — refuse rather than
        //    promote a surprise into the user's filesystem.
        progress?(.verifying)
        let extractedRoot = try Self.verifyExtractedStructure(in: staging)

        // 7. Promote. If `dest` exists it was validated empty above, so
        //    removing it is safe and lets the rename land on a clean name.
        if FileManager.default.fileExists(atPath: dest.path) {
            Self.removeIfExists(dest)
        }
        do {
            try FileManager.default.moveItem(at: extractedRoot, to: dest)
        } catch {
            throw RestoreError.finalMoveFailed(underlying: error)
        }

        let fileCount = Self.countRegularFiles(in: dest)
        progress?(.completed(restoredTo: dest, fileCount: fileCount))
        return RestoreResult(restoredPath: dest, archive: archiveURL, manifest: manifest)
    }

    // MARK: - Manifest / archive pairing

    static func decodeManifest(at url: URL) throws -> ArchiveManifest {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RestoreError.manifestUnreadable(url, underlying: error)
        }
        do {
            return try ArchiveManifest.decoder().decode(ArchiveManifest.self, from: data)
        } catch {
            throw RestoreError.manifestDecodeFailed(url, underlying: error)
        }
    }

    /// "<dir>/<base>.json" ⇒ "<dir>/<base>.tar.zst". Built from the
    /// directory + stripped base name rather than string-replacing the
    /// extension so a manifest named oddly can't smuggle in a surprise.
    static func siblingArchiveURL(for manifestURL: URL) -> URL {
        ArchiveArtifactPair(manifestURL: manifestURL).archive
    }

    // MARK: - Validation

    static func validateDestination(_ dest: URL) throws {
        let resolved = dest.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if resolved == "/" || resolved == home {
            throw RestoreError.destinationRefused(
                dest, reason: "홈 또는 루트 디렉토리로는 복원할 수 없음"
            )
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dest.path, isDirectory: &isDir) else {
            return // does not exist yet — the common, ideal case
        }
        guard isDir.boolValue else {
            throw RestoreError.destinationRefused(
                dest, reason: "대상 경로에 파일이 이미 존재함 (디렉토리가 아님)"
            )
        }
        let contents = (try? fm.contentsOfDirectory(atPath: dest.path)) ?? []
        if !contents.isEmpty {
            // Refuse rather than merge/overwrite: restoring "in place"
            // must never silently bury an existing checkout.
            throw RestoreError.destinationNotEmpty(dest)
        }
    }

    /// The archive must extract to exactly one top-level directory. Returns
    /// that directory's URL inside `staging`.
    static func verifyExtractedStructure(in staging: URL) throws -> URL {
        let fm = FileManager.default
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: staging,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        } catch {
            throw RestoreError.verificationFailed(reason: "추출 디렉토리를 읽을 수 없음: \(error.localizedDescription)")
        }
        guard entries.count == 1 else {
            throw RestoreError.verificationFailed(
                reason: "아카이브 최상위에 디렉토리 1개가 있어야 하는데 \(entries.count)개가 추출됨"
            )
        }
        let root = entries[0]
        let isDir = (try? root.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        guard isDir else {
            throw RestoreError.verificationFailed(reason: "추출된 최상위 항목이 디렉토리가 아님")
        }
        return root
    }

    // MARK: - tar invocation

    private func runTarExtract(archive: URL, into dir: URL) async throws {
        // Unlike archive creation, no `--` separator is needed here: the
        // archive path and the destination are option-ARGUMENTS to `-f` and
        // `-C`, so a leading-dash value is consumed as the flag's value and
        // never parsed as a flag. We pass no positional member arguments
        // (the whole archive is extracted), so there is no flag-shaped
        // positional to guard against.
        //
        // Path-traversal defense: we do NOT pass `-P`/`--absolute-paths`, so
        // bsdtar applies its default protections — leading slashes stripped,
        // entries containing `..` skipped. Combined with extracting into a
        // freshly created staging dir and the one-top-level-dir structure
        // check, a tampered tarball cannot write outside the staging area.
        let result = try await ProcessRunner.run(
            executable: configuration.tarExecutable,
            arguments: [
                "--zstd",
                "-xf", archive.path,
                "-C", dir.path,
            ],
            timeout: configuration.extractionTimeout,
            wrapping: RestoreError.process
        )
        guard result.isSuccess else {
            throw RestoreError.extractionFailed(stderr: result.stderr, exitCode: result.exitCode)
        }
    }

    // MARK: - Helpers

    static func countRegularFiles(in root: URL) -> Int {
        guard let en = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return 0 }
        var count = 0
        for case let url as URL in en {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                count += 1
            }
        }
        return count
    }

    static func removeIfExists(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
