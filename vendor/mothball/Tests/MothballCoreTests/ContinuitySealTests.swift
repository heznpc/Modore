import XCTest
@testable import MothballCore

/// Sealing is the step that turns "a path on this machine that a
/// retention sweep may delete" into "bytes inside the archive". These
/// tests pin the two properties that make it worth doing at all: the
/// whole session tree is captured, and the recorded digest describes the
/// bytes that actually ship.
final class ContinuitySealTests: XCTestCase {
    var scratch: URL!
    var archiveDir: URL!
    var repo: TempGitRepo!

    override func setUp() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/bin/git") &&
            FileManager.default.isExecutableFile(atPath: "/usr/bin/tar"),
            "git and tar both required at /usr/bin"
        )
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MothballSeal-\(UUID().uuidString)", directoryHint: .isDirectory)
        archiveDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MothballSealArchive-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        repo = try TempGitRepo()
    }

    override func tearDown() async throws {
        repo?.cleanup()
        for dir in [scratch, archiveDir] where dir != nil {
            try? FileManager.default.removeItem(at: dir!)
        }
    }

    // MARK: - Fixtures

    /// A transcript plus a subagent tree beside it — the shape the
    /// provider actually writes, and the shape whose second half a naive
    /// "copy the .jsonl" would drop.
    private func makeSessionOnDisk(
        id: String, subagents: Int = 2
    ) throws -> SessionBinding {
        // The provider's real layout: the transcript sits *beside* the
        // directory holding its subagent tree, not inside it.
        // `~/.claude/projects/<slug>/<id>.jsonl` next to
        // `<slug>/<id>/subagents/...`. A fixture that nests them differently
        // silently exercises the fallback path instead of the real one.
        let store = scratch.appending(path: "store", directoryHint: .isDirectory)
        let dir = store.appending(path: id, directoryHint: .isDirectory)
        let subDir = dir.appending(path: "subagents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let transcript = store.appending(path: "\(id).jsonl")
        try Data("{\"parent\":\"\(id)\"}\n".utf8).write(to: transcript)
        var subs: [URL] = []
        for i in 0..<subagents {
            let sub = subDir.appending(path: "agent-\(i).jsonl")
            try Data("{\"sub\":\(i)}\n".utf8).write(to: sub)
            subs.append(sub)
        }
        return SessionBinding(
            provider: .claude, sessionID: id, source: transcript,
            subtranscripts: subs, evidence: [.workingDirectory], confidence: .medium
        )
    }

    private func repoInfo() async throws -> RepoInfo {
        try await repo.initialize()
        try repo.writeFile("README.md")
        try await repo.commit("initial")
        try await repo.fakePushedOrigin()
        return try await RepoScanner()
            .scan(roots: [repo.url.deletingLastPathComponent()])
            .first { $0.path.standardizedFileURL == repo.url.standardizedFileURL }
            ?? XCTUnwrap(nil)
    }

    private func makeOrchestrator() -> ArchiveOrchestrator {
        ArchiveOrchestrator(configuration: .init(
            archiveDirectory: archiveDir, zstdLevel: 1,
            compressionTimeout: .seconds(60), verificationTimeout: .seconds(30)
        ))
    }

    // MARK: - Sealer

    func test_seal_copiesTranscriptAndSubagentTree() throws {
        let binding = try makeSessionOnDisk(id: "s1", subagents: 3)
        let bundle = try ContinuitySealer().seal(bindings: [binding], stagingParent: scratch)
        defer { try? FileManager.default.removeItem(at: bundle.stagingRoot) }

        let sealedDir = bundle.stagingRoot.appending(path: "sessions/claude/s1")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sealedDir.appending(path: "transcript.jsonl").path))
        for i in 0..<3 {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: sealedDir.appending(path: "subagents/agent-\(i).jsonl").path),
                "subagent \(i) must be inside the capsule, not left in the provider's store")
        }
        XCTAssertEqual(bundle.sessions.first?.fileCount, 4)
    }

    /// The provider's own cleanup deletes the parent transcript and
    /// leaves the subagent tree behind. A digest over only the parent
    /// would therefore verify the smaller half of what was preserved.
    func test_treeDigest_coversSubagentsNotJustTheParent() throws {
        let binding = try makeSessionOnDisk(id: "s2", subagents: 1)
        let first = try ContinuitySealer().seal(bindings: [binding], stagingParent: scratch)
        defer { try? FileManager.default.removeItem(at: first.stagingRoot) }

        try Data("{\"sub\":999}\n".utf8).write(to: binding.subtranscripts[0])
        let second = try ContinuitySealer().seal(bindings: [binding], stagingParent: scratch)
        defer { try? FileManager.default.removeItem(at: second.stagingRoot) }

        XCTAssertNotEqual(first.sessions[0].sha256, second.sessions[0].sha256,
                          "changing a subagent transcript must change the digest")
    }

    func test_treeDigest_isStableForIdenticalContent() throws {
        let binding = try makeSessionOnDisk(id: "s3", subagents: 2)
        let a = try ContinuitySealer().seal(bindings: [binding], stagingParent: scratch)
        let b = try ContinuitySealer().seal(bindings: [binding], stagingParent: scratch)
        defer {
            try? FileManager.default.removeItem(at: a.stagingRoot)
            try? FileManager.default.removeItem(at: b.stagingRoot)
        }
        XCTAssertEqual(a.sessions[0].sha256, b.sessions[0].sha256)
    }

    /// The reason sealing copies before hashing. An agent can append to
    /// its own transcript at any moment; if the digest described the live
    /// file and the tar ran afterwards, the manifest would certify bytes
    /// the archive does not contain.
    func test_mutatingOriginalAfterSeal_doesNotInvalidateTheRecordedDigest() throws {
        let binding = try makeSessionOnDisk(id: "s4", subagents: 1)
        let bundle = try ContinuitySealer().seal(bindings: [binding], stagingParent: scratch)
        defer { try? FileManager.default.removeItem(at: bundle.stagingRoot) }
        let recorded = bundle.sessions[0].sha256

        // The agent keeps writing after we sealed.
        let handle = try FileHandle(forWritingTo: binding.source)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"appended\":true}\n".utf8))
        try handle.close()

        let staged = try ContinuitySealer.treeDigest(
            of: bundle.stagingRoot.appending(path: "sessions/claude/s4")
        )
        XCTAssertEqual(staged.digest, recorded,
                       "the manifest must describe the staged copy, which cannot change")
    }

    /// The shape the provider actually writes, found by sealing a real
    /// 163-session store: subagent transcripts are nested under
    /// `subagents/workflows/<wf-id>/`, and every workflow has its own
    /// `journal.jsonl`. Copying by `lastPathComponent` collapses those
    /// onto one destination and the second copy fails outright, so a flat
    /// fixture proves nothing about the real store.
    func test_seal_preservesNestedSubagentLayoutAndCollidingFilenames() throws {
        let dir = scratch.appending(path: "store/nested", directoryHint: .isDirectory)
        let transcript = dir.appendingPathExtension("jsonl")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: transcript)

        var subs: [URL] = []
        for wf in ["wf_aaa", "wf_bbb"] {
            let wfDir = dir.appending(path: "subagents/workflows/\(wf)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: wfDir, withIntermediateDirectories: true)
            for name in ["journal.jsonl", "agent-1.jsonl"] {
                let file = wfDir.appending(path: name)
                try Data("{\"wf\":\"\(wf)\"}\n".utf8).write(to: file)
                subs.append(file)
            }
        }

        let binding = SessionBinding(
            provider: .claude, sessionID: "nested", source: transcript,
            subtranscripts: subs, evidence: [.workingDirectory], confidence: .medium
        )
        let bundle = try ContinuitySealer().seal(bindings: [binding], stagingParent: scratch)
        defer { try? FileManager.default.removeItem(at: bundle.stagingRoot) }

        let sealedDir = bundle.stagingRoot.appending(path: "sessions/claude/nested")
        for wf in ["wf_aaa", "wf_bbb"] {
            for name in ["journal.jsonl", "agent-1.jsonl"] {
                let path = sealedDir.appending(path: "subagents/workflows/\(wf)/\(name)")
                XCTAssertTrue(FileManager.default.fileExists(atPath: path.path),
                              "\(wf)/\(name) must survive with its layout intact")
            }
        }
        // 4 subagents + 1 transcript. A collapse would silently lose one.
        XCTAssertEqual(bundle.sessions.first?.fileCount, 5)
    }

    /// A subtranscript outside the session directory would collide on
    /// filename alone; it keeps a path-derived prefix instead. Losing a
    /// transcript quietly is the failure this type exists to prevent.
    func test_relativePath_disambiguatesFilesOutsideTheSessionDirectory() {
        let origin = URL(fileURLWithPath: "/store/session")
        let inside = URL(fileURLWithPath: "/store/session/subagents/a/journal.jsonl")
        XCTAssertEqual(
            ContinuitySealer.relativePath(of: inside, under: origin),
            "subagents/a/journal.jsonl"
        )
        let strayA = URL(fileURLWithPath: "/elsewhere/one/journal.jsonl")
        let strayB = URL(fileURLWithPath: "/elsewhere/two/journal.jsonl")
        XCTAssertNotEqual(
            ContinuitySealer.relativePath(of: strayA, under: origin),
            ContinuitySealer.relativePath(of: strayB, under: origin)
        )
    }

    // MARK: - Orchestrator integration

    func test_notAssessed_blocksAndLeavesNothingBehind() async throws {
        let info = try await repoInfo()
        do {
            _ = try await makeOrchestrator().archive(info, continuity: .notAssessed)
            XCTFail("an unassessed workspace must not be archivable")
        } catch let error as ArchiveOrchestrator.ArchiveError {
            guard case .continuityRefused(.notAssessed) = error else {
                return XCTFail("expected continuityRefused(.notAssessed), got \(error)")
            }
        }
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: archiveDir, includingPropertiesForKeys: nil)
        XCTAssertTrue(leftovers.isEmpty, "a refusal must cost nothing: \(leftovers)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.url.path),
                      "the original must still be there")
    }

    func test_unsealedBindings_blockTheArchive() async throws {
        let info = try await repoInfo()
        let binding = try makeSessionOnDisk(id: "s5")
        do {
            _ = try await makeOrchestrator().archive(info, continuity: .bindings([binding], coverage: .complete))
            XCTFail("sessions that are still only in the provider's store must block")
        } catch let error as ArchiveOrchestrator.ArchiveError {
            guard case .continuityRefused(.unsealedSessions(let count)) = error, count == 1 else {
                return XCTFail("expected unsealedSessions(1), got \(error)")
            }
        }
    }

    func test_sealedSessions_produceASiblingArchiveRecordedInTheManifest() async throws {
        let info = try await repoInfo()
        let bundle = try ContinuitySealer().seal(
            bindings: [try makeSessionOnDisk(id: "s6", subagents: 2)],
            stagingParent: scratch
        )
        defer { try? FileManager.default.removeItem(at: bundle.stagingRoot) }

        let result = try await makeOrchestrator().archive(info, continuity: .sealed(bundle, coverage: .complete))

        let sessionArchive = try XCTUnwrap(result.sessionArchive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionArchive.path))
        XCTAssertTrue(sessionArchive.lastPathComponent.hasSuffix(".sessions.tar.zst"))

        let manifest = try Restorer.decodeManifest(at: result.manifest)
        XCTAssertEqual(manifest.schemaVersion, 2)
        XCTAssertEqual(manifest.continuity?.assessment, "sealed")
        XCTAssertEqual(manifest.continuity?.sessionArchive, sessionArchive.lastPathComponent)
        XCTAssertEqual(manifest.continuity?.sessions.count, 1)
        XCTAssertEqual(manifest.continuity?.sessions.first?.fileCount, 3)
    }

    /// The workspace archive keeps its one-top-level-directory shape.
    /// That invariant is what `Restorer.verifyExtractedStructure` checks
    /// before promoting anything into the user's filesystem, and it is
    /// why the sessions went into a sibling file instead of a second
    /// directory inside this one.
    func test_workspaceArchiveStaysSingleRooted_evenWithSessions() async throws {
        let info = try await repoInfo()
        let bundle = try ContinuitySealer().seal(
            bindings: [try makeSessionOnDisk(id: "s7")], stagingParent: scratch
        )
        defer { try? FileManager.default.removeItem(at: bundle.stagingRoot) }
        let result = try await makeOrchestrator().archive(info, continuity: .sealed(bundle, coverage: .complete))

        let listing = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["--zstd", "-tf", result.archive.path],
            timeout: .seconds(30)
        )
        let roots = Set(listing.stdout
            .split(separator: "\n")
            .compactMap { $0.split(separator: "/").first.map(String.init) })
        XCTAssertEqual(roots.count, 1, "workspace archive must stay single-rooted, got \(roots)")
    }

    func test_sessionArchiveExtractsToASingleSessionsDirectory() async throws {
        let info = try await repoInfo()
        let bundle = try ContinuitySealer().seal(
            bindings: [try makeSessionOnDisk(id: "s8")], stagingParent: scratch
        )
        defer { try? FileManager.default.removeItem(at: bundle.stagingRoot) }
        let result = try await makeOrchestrator().archive(info, continuity: .sealed(bundle, coverage: .complete))

        let listing = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["--zstd", "-tf", try XCTUnwrap(result.sessionArchive).path],
            timeout: .seconds(30)
        )
        let entries = listing.stdout.split(separator: "\n").map(String.init)
        XCTAssertTrue(entries.allSatisfy { $0.hasPrefix("sessions/") },
                      "session archive must be rooted at `sessions/`")
        XCTAssertTrue(entries.contains { $0.hasSuffix("claude/s8/transcript.jsonl") })
        XCTAssertTrue(entries.contains { $0.contains("subagents/") })
    }

    func test_noSessions_writesNoSiblingArchiveButStillRecordsTheAssessment() async throws {
        let info = try await repoInfo()
        let result = try await makeOrchestrator().archive(info, continuity: .assessedNoSessions)
        XCTAssertNil(result.sessionArchive)

        let manifest = try Restorer.decodeManifest(at: result.manifest)
        // Present, not absent: a v2 archive claims positively that a
        // binder ran and found nothing, which a missing block cannot say.
        XCTAssertEqual(manifest.continuity?.assessment, "assessed-no-sessions")
        XCTAssertNil(manifest.continuity?.sessionArchive)
        XCTAssertNil(manifest.continuity?.overrideReason)
    }

    /// Nothing writes an override any more. The gate has no case that
    /// allows without either a finding or a completed empty look, so a
    /// manifest cannot claim a decision no one made.
    func test_noAssessmentWritesAnOverride() async throws {
        let info = try await repoInfo()
        let result = try await makeOrchestrator().archive(info, continuity: .assessedNoSessions)
        let manifest = try Restorer.decodeManifest(at: result.manifest)
        XCTAssertNil(manifest.continuity?.overrideReason)
    }
}

/// Restoring the working tree without the conversations puts the user
/// back exactly where the gate exists to stop them getting: the code
/// returns, the reasoning behind it does not. So the round trip has to
/// carry both, and the digests have to be checked on the way back --
/// a manifest that promises sessions and delivers unverifiable bytes is
/// the false assurance this design is built to avoid.
final class SessionRestoreRoundTripTests: XCTestCase {
    var scratch: URL!
    var archiveDir: URL!
    var restoreParent: URL!
    var repo: TempGitRepo!

    override func setUp() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/bin/git") &&
            FileManager.default.isExecutableFile(atPath: "/usr/bin/tar"),
            "git and tar both required at /usr/bin"
        )
        scratch = try Self.tempDir("SessionRestoreScratch")
        archiveDir = try Self.tempDir("SessionRestoreArchive")
        restoreParent = try Self.tempDir("SessionRestoreDest")
        repo = try TempGitRepo()
    }

    override func tearDown() async throws {
        repo?.cleanup()
        for dir in [scratch, archiveDir, restoreParent] where dir != nil {
            try? FileManager.default.removeItem(at: dir!)
        }
    }

    private static func tempDir(_ prefix: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sealedBundle(id: String = "round") throws -> ContinuityBundle {
        let store = scratch.appending(path: "store", directoryHint: .isDirectory)
        let dir = store.appending(path: id, directoryHint: .isDirectory)
        let subDir = dir.appending(path: "subagents/workflows/wf_a", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let transcript = store.appending(path: "\(id).jsonl")
        try Data("{\"parent\":true}\n".utf8).write(to: transcript)
        let sub = subDir.appending(path: "journal.jsonl")
        try Data("{\"sub\":true}\n".utf8).write(to: sub)

        return try ContinuitySealer().seal(
            bindings: [SessionBinding(
                provider: .claude, sessionID: id, source: transcript,
                subtranscripts: [sub], evidence: [.workingDirectory], confidence: .medium
            )],
            stagingParent: scratch
        )
    }

    private func archiveWithSessions() async throws -> ArchiveOrchestrator.ArchiveResult {
        try await repo.initialize()
        try repo.writeFile("README.md", contents: "round trip\n")
        try await repo.commit("initial")
        try await repo.fakePushedOrigin()
        let scanned = await RepoScanner().scan(roots: [repo.url.deletingLastPathComponent()])
        let info = try XCTUnwrap(
            scanned.first { $0.path.standardizedFileURL == repo.url.standardizedFileURL }
        )
        let bundle = try sealedBundle()
        defer { try? FileManager.default.removeItem(at: bundle.stagingRoot) }
        return try await ArchiveOrchestrator(configuration: .init(
            archiveDirectory: archiveDir, zstdLevel: 1,
            compressionTimeout: .seconds(60), verificationTimeout: .seconds(30)
        )).archive(info, continuity: .sealed(bundle, coverage: .complete))
    }

    func test_restoreBringsBackTheSessionsAndVerifiesTheirDigests() async throws {
        let archived = try await archiveWithSessions()
        let dest = restoreParent.appending(path: "back", directoryHint: .isDirectory)

        let restored = try await Restorer().restore(manifestURL: archived.manifest, to: dest)

        XCTAssertEqual(restored.verifiedSessionCount, 1)
        let sessions = try XCTUnwrap(restored.restoredSessions)
        let transcript = sessions.appending(path: "sessions/claude/round/transcript.jsonl")
        let sub = sessions.appending(path: "sessions/claude/round/subagents/workflows/wf_a/journal.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sub.path),
                      "the subagent tree has to survive the round trip too")
    }

    /// A manifest whose sessions no longer hash to what it recorded is
    /// worse than one with no sessions at all: it certifies bytes nobody
    /// can trust. Restore refuses rather than handing them back quietly.
    func test_tamperedSessionArchiveFailsTheRestore() async throws {
        let archived = try await archiveWithSessions()
        let sessionArchive = try XCTUnwrap(archived.sessionArchive)

        // Repack the session archive with different bytes under the same
        // name, leaving the manifest's digest describing the old content.
        let fake = restoreParent.appending(path: "fake/sessions/claude/round", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        try Data("{\"tampered\":true}\n".utf8).write(to: fake.appending(path: "transcript.jsonl"))
        try FileManager.default.removeItem(at: sessionArchive)
        _ = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["--zstd", "-cf", sessionArchive.path,
                        "-C", restoreParent.appending(path: "fake").path, "--", "sessions"],
            timeout: .seconds(30)
        )

        let dest = restoreParent.appending(path: "back2", directoryHint: .isDirectory)
        do {
            _ = try await Restorer().restore(manifestURL: archived.manifest, to: dest)
            XCTFail("a session digest mismatch must fail the restore")
        } catch Restorer.RestoreError.sessionDigestMismatch(let id, _, _) {
            XCTAssertEqual(id, "round")
        }
    }

    func test_missingSessionArchiveFailsRatherThanRestoringHalfTheRecord() async throws {
        let archived = try await archiveWithSessions()
        try FileManager.default.removeItem(at: try XCTUnwrap(archived.sessionArchive))

        let dest = restoreParent.appending(path: "back3", directoryHint: .isDirectory)
        do {
            _ = try await Restorer().restore(manifestURL: archived.manifest, to: dest)
            XCTFail("a manifest promising sessions must not restore without them")
        } catch Restorer.RestoreError.sessionArchiveMissing {
            // expected
        }
    }
}

extension SessionRestoreRoundTripTests {

    /// Everything that can refuse has to refuse before anything moves. A
    /// digest mismatch found after the working tree is in place leaves a
    /// half-restored repo behind and reports only a thrown error, which is
    /// the worst of both: the caller believes nothing happened and the
    /// filesystem disagrees.
    func test_aSessionMismatchLeavesTheDestinationUntouched() async throws {
        let archived = try await archiveWithSessionsForTamper()
        let sessionArchive = try XCTUnwrap(archived.sessionArchive)

        let fake = restoreParent.appending(path: "fake2/sessions/claude/round", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        try Data("{\"tampered\":true}\n".utf8).write(to: fake.appending(path: "transcript.jsonl"))
        try FileManager.default.removeItem(at: sessionArchive)
        _ = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["--zstd", "-cf", sessionArchive.path,
                        "-C", restoreParent.appending(path: "fake2").path, "--", "sessions"],
            timeout: .seconds(30)
        )

        let dest = restoreParent.appending(path: "atomic", directoryHint: .isDirectory)
        do {
            _ = try await Restorer().restore(manifestURL: archived.manifest, to: dest)
            XCTFail("expected the mismatch to fail the restore")
        } catch Restorer.RestoreError.sessionDigestMismatch {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: dest.path),
                "a refused restore must not leave a repo behind"
            )
        }
    }

    /// Conversations coming back readable is not the same as the provider
    /// being able to resume them, and the result says which it is rather
    /// than leaving it to be inferred.
    func test_restoreReportsReadableButNotProviderResumable() async throws {
        let archived = try await archiveWithSessionsForTamper()
        let dest = restoreParent.appending(path: "readable", directoryHint: .isDirectory)
        let restored = try await Restorer().restore(manifestURL: archived.manifest, to: dest)
        XCTAssertTrue(restored.sessionsReadable)
        XCTAssertFalse(restored.providerResumable,
                       "restored transcripts live in the repo, not the provider's store")
    }

    private func archiveWithSessionsForTamper() async throws -> ArchiveOrchestrator.ArchiveResult {
        try await repo.initialize()
        try repo.writeFile("README.md", contents: "atomic\n")
        try await repo.commit("initial")
        try await repo.fakePushedOrigin()
        let scanned = await RepoScanner().scan(roots: [repo.url.deletingLastPathComponent()])
        let info = try XCTUnwrap(
            scanned.first { $0.path.standardizedFileURL == repo.url.standardizedFileURL }
        )
        let bundle = try sealedBundleForTamper()
        defer { try? FileManager.default.removeItem(at: bundle.stagingRoot) }
        return try await ArchiveOrchestrator(configuration: .init(
            archiveDirectory: archiveDir, zstdLevel: 1,
            compressionTimeout: .seconds(60), verificationTimeout: .seconds(30)
        )).archive(info, continuity: .sealed(bundle, coverage: .complete))
    }

    private func sealedBundleForTamper() throws -> ContinuityBundle {
        let store = scratch.appending(path: "store2", directoryHint: .isDirectory)
        let dir = store.appending(path: "round", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let transcript = store.appending(path: "round.jsonl")
        try Data("{\"parent\":true}\n".utf8).write(to: transcript)
        return try ContinuitySealer().seal(
            bindings: [SessionBinding(
                provider: .claude, sessionID: "round", source: transcript,
                evidence: [.workingDirectory], confidence: .medium
            )],
            stagingParent: scratch
        )
    }
}

/// Providers do not all write JSONL. Sealing a Gemini `.json` or an
/// editor's `workspace.json` under a fixed `transcript.jsonl` produces a
/// capsule whose filenames describe a format the bytes do not have.
final class TranscriptNamingTests: XCTestCase {

    private func binding(_ path: String, provider: SessionProvider = .claude) -> SessionBinding {
        SessionBinding(
            provider: provider, sessionID: "s",
            source: URL(fileURLWithPath: path),
            evidence: [.workingDirectory], confidence: .medium
        )
    }

    func test_keepsTheProvidersExtension() {
        XCTAssertEqual(
            ContinuitySealer.transcriptName(for: binding("/s/abc.jsonl")),
            "transcript.jsonl"
        )
        XCTAssertEqual(
            ContinuitySealer.transcriptName(for: binding("/s/session.json", provider: .gemini)),
            "transcript.json"
        )
    }

    /// The stem stays fixed so a reader finds the top-level record
    /// without knowing which tool wrote it.
    func test_stemIsStableAcrossProviders() {
        for name in ["/s/a.jsonl", "/s/b.json", "/s/workspace.json"] {
            XCTAssertTrue(
                ContinuitySealer.transcriptName(for: binding(name)).hasPrefix("transcript"),
                name
            )
        }
    }

    func test_extensionlessSourceGetsNoInventedExtension() {
        XCTAssertEqual(ContinuitySealer.transcriptName(for: binding("/s/rollout")), "transcript")
    }

    /// Editors keep per-workspace state rather than a conversation, and
    /// the UI has to be able to say so: "three conversations" and "three
    /// editor windows remembered this folder" are different warnings.
    func test_providersDeclareWhetherTheyKeepTranscripts() {
        XCTAssertTrue(SessionProvider.claude.keepsTranscripts)
        XCTAssertTrue(SessionProvider.gemini.keepsTranscripts)
        XCTAssertFalse(SessionProvider.vscode.keepsTranscripts)
        XCTAssertFalse(SessionProvider.kiro.keepsTranscripts)
    }

    /// Provider ids are on-disk identity in every manifest already
    /// written; a rename would strand them.
    func test_providerRawValuesAreStable() {
        XCTAssertEqual(
            Set(SessionProvider.allCases.map(\.rawValue)),
            ["claude", "codex", "gemini", "vscode", "kiro", "cursor", "windsurf", "antigravity"]
        )
    }
}

/// The step that was missing: `.bindings` had no way to become
/// `.sealed` outside a test, so a caller that did the binding work still
/// hit the gate and the seal path had no product caller at all.
final class ContinuityPreparationTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "Prepare-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func binding(_ id: String) throws -> SessionBinding {
        let store = scratch.appending(path: "store", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let transcript = store.appending(path: "\(id).jsonl")
        try Data("{\"a\":1}\n".utf8).write(to: transcript)
        return SessionBinding(
            provider: .claude, sessionID: id, source: transcript,
            evidence: [.workingDirectory], confidence: .medium, sizeBytes: 7
        )
    }

    func test_sealingTurnsFoundSessionsIntoKeptOnes() throws {
        let prepared = try ContinuityPreparation.seal(
            .bindings([try binding("a")], coverage: .complete), stagingParent: scratch
        )
        defer { prepared.stagingRoot.map { try? FileManager.default.removeItem(at: $0) } }
        guard case .sealed(let bundle, let coverage) = prepared.assessment else {
            return XCTFail("expected sealed, got \(prepared.assessment)")
        }
        XCTAssertEqual(bundle.sessions.count, 1)
        XCTAssertEqual(coverage, .complete)
        XCTAssertNotNil(prepared.stagingRoot)
        XCTAssertEqual(ContinuityGate.evaluate(prepared.assessment), .allow)
    }

    /// Copying bytes says nothing about the stores nobody read, so a
    /// partial scan stays partial through sealing and the gate still
    /// refuses.
    func test_sealingDoesNotUpgradeCoverage() throws {
        let prepared = try ContinuityPreparation.seal(
            .bindings([try binding("b")], coverage: .shallow), stagingParent: scratch
        )
        defer { prepared.stagingRoot.map { try? FileManager.default.removeItem(at: $0) } }
        XCTAssertEqual(prepared.assessment.coverage, .shallow)
        XCTAssertEqual(
            ContinuityGate.evaluate(prepared.assessment),
            .block(.incompleteCoverage(.shallow))
        )
    }

    /// A binder that found nothing should have said `assessedNoSessions`.
    /// Sealing an empty list into `.sealed` would launder that caller bug
    /// into a pass.
    func test_emptyBindingsAreNotLaunderedIntoASeal() throws {
        let prepared = try ContinuityPreparation.seal(
            .bindings([], coverage: .complete), stagingParent: scratch
        )
        XCTAssertNil(prepared.stagingRoot)
        XCTAssertEqual(
            ContinuityGate.evaluate(prepared.assessment),
            .block(.unsealedSessions(count: 0))
        )
    }

    func test_statesWithNothingToPreservePassThroughUnchanged() throws {
        for assessment in [ContinuityAssessment.notAssessed, .assessedNoSessions] {
            let prepared = try ContinuityPreparation.seal(assessment, stagingParent: scratch)
            XCTAssertNil(prepared.stagingRoot)
            XCTAssertEqual(
                ContinuityGate.evaluate(prepared.assessment),
                ContinuityGate.evaluate(assessment)
            )
        }
    }

    /// The cost has to be showable before the copy, not discovered after:
    /// one repo on this machine seals 387 MB.
    func test_estimateReportsWhatSealingWouldCopy() throws {
        let bindings = [try binding("c"), try binding("d")]
        XCTAssertEqual(
            ContinuityPreparation.estimatedBytes(.bindings(bindings, coverage: .complete)),
            14
        )
        XCTAssertEqual(ContinuityPreparation.estimatedBytes(.notAssessed), 0)
    }
}

/// What a failed seal leaves behind is not an ordinary temp file: it is
/// a partial copy of the user's transcripts, in the archive directory,
/// that nobody holds a reference to. The caller cannot clean up a path
/// it was never handed, so the sealer owns it until it hands it back.
final class SealFailureCleanupTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "SealFail-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func stagingLeftovers() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".mothball-continuity-") }
    }

    private func readable(_ id: String) throws -> SessionBinding {
        let store = scratch.appending(path: "store", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let file = store.appending(path: "\(id).jsonl")
        try Data("{\"ok\":1}\n".utf8).write(to: file)
        return SessionBinding(provider: .claude, sessionID: id, source: file,
                              evidence: [.workingDirectory], confidence: .medium)
    }

    /// The failure that matters: the first session copies fine, so a
    /// partial tree exists by the time the second one throws.
    func test_failureOnASecondSessionLeavesNoPartialCopy() throws {
        let missing = SessionBinding(
            provider: .claude, sessionID: "gone",
            source: scratch.appending(path: "store/never-written.jsonl"),
            evidence: [.workingDirectory], confidence: .medium
        )
        XCTAssertThrowsError(
            try ContinuitySealer().seal(
                bindings: [try readable("first"), missing], stagingParent: scratch
            )
        )
        XCTAssertEqual(try stagingLeftovers(), [],
                       "a failed seal must not leave transcript copies behind")
    }

    func test_successStillHandsTheStagingTreeToTheCaller() throws {
        let bundle = try ContinuitySealer().seal(
            bindings: [try readable("kept")], stagingParent: scratch
        )
        XCTAssertEqual(try stagingLeftovers().map(\.lastPathComponent),
                       [bundle.stagingRoot.lastPathComponent],
                       "a successful seal keeps the tree for the caller to compress")
        try FileManager.default.removeItem(at: bundle.stagingRoot)
    }
}

/// An editor keeps `workspace.json` *inside* the entry, beside `chat/`
/// and `panels/`. Inferring the root from the filename put it at
/// `<entry>/workspace`, so every sibling fell outside and flattened into
/// digest-prefixed basenames -- two `a.json` from different folders
/// became two unrelated files and the tree stopped meaning anything.
final class EditorArtifactRootTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "EditorRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func editorBinding(withRoot: Bool) throws -> SessionBinding {
        let entry = scratch.appending(path: "workspaceStorage/abc", directoryHint: .isDirectory)
        for folder in ["chat", "panels"] {
            try FileManager.default.createDirectory(
                at: entry.appending(path: folder, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
            try Data("{\"in\":\"\(folder)\"}\n".utf8)
                .write(to: entry.appending(path: "\(folder)/a.json"))
        }
        let manifest = entry.appending(path: "workspace.json")
        try Data("{\"folder\":\"file:///w\"}\n".utf8).write(to: manifest)
        return SessionBinding(
            provider: .vscode, sessionID: "abc", source: manifest,
            subtranscripts: [entry.appending(path: "chat/a.json"),
                             entry.appending(path: "panels/a.json")],
            artifactRoot: withRoot ? entry : nil,
            evidence: [.workingDirectory], confidence: .medium
        )
    }

    func test_editorStateKeepsItsDirectoryStructure() throws {
        let bundle = try ContinuitySealer().seal(
            bindings: [try editorBinding(withRoot: true)], stagingParent: scratch
        )
        defer { try? FileManager.default.removeItem(at: bundle.stagingRoot) }
        let sealed = bundle.stagingRoot.appending(path: "sessions/vscode/abc")
        for folder in ["chat", "panels"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: sealed.appending(path: "\(folder)/a.json").path),
                "\(folder)/a.json must keep its folder"
            )
        }
    }

    /// Same files, no stated root: the old inference, kept as a test so
    /// the regression is visible rather than remembered.
    func test_withoutAStatedRootTheTreeCollapses() throws {
        let bundle = try ContinuitySealer().seal(
            bindings: [try editorBinding(withRoot: false)], stagingParent: scratch
        )
        defer { try? FileManager.default.removeItem(at: bundle.stagingRoot) }
        let sealed = bundle.stagingRoot.appending(path: "sessions/vscode/abc")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sealed.appending(path: "chat/a.json").path),
            "this is the layout the binder must not leave to inference"
        )
        // Both survive as bytes, which is why the loss is quiet.
        XCTAssertEqual(bundle.sessions.first?.fileCount, 3)
    }

    /// The agent stores keep working on the fallback: transcript beside a
    /// directory of the same stem.
    func test_agentStoresStillWorkWithoutAStatedRoot() throws {
        let store = scratch.appending(path: "store", directoryHint: .isDirectory)
        let dir = store.appending(path: "s", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: dir.appending(path: "subagents", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let transcript = store.appending(path: "s.jsonl")
        try Data("{}\n".utf8).write(to: transcript)
        let sub = dir.appending(path: "subagents/agent.jsonl")
        try Data("{}\n".utf8).write(to: sub)

        let bundle = try ContinuitySealer().seal(
            bindings: [SessionBinding(
                provider: .claude, sessionID: "s", source: transcript,
                subtranscripts: [sub], evidence: [.workingDirectory], confidence: .medium
            )],
            stagingParent: scratch
        )
        defer { try? FileManager.default.removeItem(at: bundle.stagingRoot) }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bundle.stagingRoot
                .appending(path: "sessions/claude/s/subagents/agent.jsonl").path
        ))
    }
}

/// A provider's session identifier is data it wrote, not a path this
/// build chose. `URL.appending(path:)` does not confine it -- verified
/// directly: appending `../../../escaped` to
/// `/tmp/base/sessions/codex` resolves to `/tmp/escaped`. Copies landing
/// there survive the sealer's failure cleanup, which removes only the
/// staging root, so this reopens exactly the leak that cleanup closes.
final class ArtifactKeyTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ArtifactKey-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    /// Real ids stay readable: someone opening an archive years later
    /// should still recognise `sessions/claude/3a4f0f71-…/`.
    func test_ordinaryIdentifiersPassThroughUnchanged() {
        for id in ["3a4f0f71-b5a7-7ce2-9b40-35efdee18d84",
                   "019f5bf7-b5a7-7ce2", "session-2026-06-04T08-10-fd2c2ead", "abc123"] {
            XCTAssertEqual(ArtifactKey.derive(provider: .claude, sessionID: id), id)
        }
    }

    func test_traversalAndSeparatorsAreReplaced() {
        for id in ["../../../escaped", "..", ".", "a/b", "", "with space", ".hidden"] {
            let key = ArtifactKey.derive(provider: .codex, sessionID: id)
            XCTAssertNotEqual(key, id, id)
            XCTAssertTrue(ArtifactKey.isSafeComponent(key), "\(id) → \(key)")
        }
    }

    /// Two stores must not collide on the same unsafe id.
    func test_derivationIsProviderScopedAndDeterministic() {
        let a = ArtifactKey.derive(provider: .claude, sessionID: "../x")
        let b = ArtifactKey.derive(provider: .codex, sessionID: "../x")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, ArtifactKey.derive(provider: .claude, sessionID: "../x"))
    }

    /// The end-to-end property: nothing lands outside the staging tree,
    /// and the manifest still records the real identifier.
    func test_sealingAHostileIdentifierWritesNothingOutsideStaging() throws {
        let store = scratch.appending(path: "store", directoryHint: .isDirectory)
        let guardrail = scratch.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: guardrail, withIntermediateDirectories: true)
        let transcript = store.appending(path: "t.jsonl")
        try Data("{\"secret\":\"transcript\"}\n".utf8).write(to: transcript)

        let bundle = try ContinuitySealer().seal(
            bindings: [SessionBinding(
                provider: .codex, sessionID: "../../../outside/leaked",
                source: transcript, evidence: [.remoteURL], confidence: .high
            )],
            stagingParent: scratch
        )
        defer { try? FileManager.default.removeItem(at: bundle.stagingRoot) }

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: guardrail.path), [],
            "a transcript copy must not land outside the staging tree"
        )
        let sealed = try XCTUnwrap(bundle.sessions.first)
        XCTAssertTrue(sealed.artifact.hasPrefix("sessions/codex/"), sealed.artifact)
        XCTAssertFalse(sealed.artifact.contains(".."), sealed.artifact)
        // The provider's own identifier is still recorded; only the path
        // refuses to trust it.
        XCTAssertEqual(sealed.sessionID, "../../../outside/leaked")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bundle.stagingRoot.appending(path: sealed.artifact).path
        ))
    }

    func test_containmentCheckRejectsAnEscapingDestination() {
        let root = URL(fileURLWithPath: "/tmp/base/sessions")
        XCTAssertTrue(ContinuitySealer.isContained(
            root.appending(path: "codex/ok"), within: root))
        XCTAssertFalse(ContinuitySealer.isContained(
            URL(fileURLWithPath: "/tmp/base/elsewhere"), within: root))
    }
}

/// Records whether a `@Sendable` closure ran, without the data race a
/// captured `var` would be.
actor RanFlag {
    private(set) var value = false
    func mark() { value = true }
}

/// An assessment is a statement about a moment. Sealing hundreds of
/// megabytes takes long enough for the tree to move or an agent to write
/// a new session, and every check upstream of the archive ran on the
/// older world.
final class RevalidationTests: XCTestCase {
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
            .appending(path: "Reval-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        repo?.cleanup()
        if let archiveDir { try? FileManager.default.removeItem(at: archiveDir) }
    }

    private func repoInfo() async throws -> RepoInfo {
        try await repo.initialize()
        try repo.writeFile("README.md")
        try await repo.commit("initial")
        try await repo.fakePushedOrigin()
        let scanned = await RepoScanner().scan(roots: [repo.url.deletingLastPathComponent()])
        return try XCTUnwrap(scanned.first { $0.path.standardizedFileURL == repo.url.standardizedFileURL })
    }

    private func orchestrator() -> ArchiveOrchestrator {
        ArchiveOrchestrator(configuration: .init(
            archiveDirectory: archiveDir, zstdLevel: 1,
            compressionTimeout: .seconds(60), verificationTimeout: .seconds(30)
        ))
    }

    /// A refusal here must cost nothing but the seal that already
    /// happened -- no archive, no sidecar, and the original untouched.
    func test_aFailedRevalidationWritesNothingAndKeepsTheOriginal() async throws {
        let info = try await repoInfo()
        do {
            _ = try await orchestrator().archive(
                info, continuity: .assessedNoSessions,
                revalidate: {
                    throw ArchiveOrchestrator.ArchiveError.revalidationFailed(
                        reason: "봉인 중 새 세션이 생겼습니다"
                    )
                }
            )
            XCTFail("a failed revalidation must stop the archive")
        } catch ArchiveOrchestrator.ArchiveError.revalidationFailed(let reason) {
            XCTAssertEqual(reason, "봉인 중 새 세션이 생겼습니다")
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: nil),
            []
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.url.path))
    }

    /// It runs after the gate, so a workspace that was going to be
    /// refused anyway is refused for the reason that came first.
    func test_theGateStillDecidesBeforeRevalidationRuns() async throws {
        let info = try await repoInfo()
        let revalidated = RanFlag()
        do {
            _ = try await orchestrator().archive(
                info, continuity: .notAssessed,
                revalidate: { await revalidated.mark() }
            )
            XCTFail("expected the gate to refuse")
        } catch ArchiveOrchestrator.ArchiveError.continuityRefused {
            let ran = await revalidated.value
            XCTAssertFalse(ran, "an ungated archive must not pay for a revalidation")
        }
    }

    func test_apassingRevalidationLetsTheArchiveThrough() async throws {
        let info = try await repoInfo()
        let result = try await orchestrator().archive(
            info, continuity: .assessedNoSessions, revalidate: {}
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.archive.path))
    }

    /// Git drift compares the facts the safety judgement rested on. A new
    /// untracked scratch file is not a reason to refuse; a moved HEAD is.
    func test_gitDriftNamesWhatChanged() {
        let base = GitMetadata(lastCommitDate: nil, isDirty: false, aheadOfOrigin: 0,
                               originURL: "o", currentBranch: "main", headSHA: "aaa")
        XCTAssertNil(ContinuityPreparation.gitDrift(from: base, to: base))

        let moved = GitMetadata(lastCommitDate: nil, isDirty: false, aheadOfOrigin: 0,
                                originURL: "o", currentBranch: "main", headSHA: "bbb")
        XCTAssertTrue(ContinuityPreparation.gitDrift(from: base, to: moved)?.contains("커밋") ?? false)

        let dirty = GitMetadata(lastCommitDate: nil, isDirty: true, aheadOfOrigin: 0,
                                originURL: "o", currentBranch: "main", headSHA: "aaa")
        XCTAssertNotNil(ContinuityPreparation.gitDrift(from: base, to: dirty))

        let branched = GitMetadata(lastCommitDate: nil, isDirty: false, aheadOfOrigin: 0,
                                   originURL: "o", currentBranch: "other", headSHA: "aaa")
        XCTAssertNotNil(ContinuityPreparation.gitDrift(from: base, to: branched))
    }
}
