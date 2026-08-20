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

    func test_userOverride_isWrittenIntoTheManifest() async throws {
        let info = try await repoInfo()
        let result = try await makeOrchestrator().archive(
            info, continuity: .overriddenByUser(reason: "no binder in standalone")
        )
        let manifest = try Restorer.decodeManifest(at: result.manifest)
        XCTAssertEqual(manifest.continuity?.assessment, "overridden-by-user")
        XCTAssertEqual(manifest.continuity?.overrideReason, "no binder in standalone")
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
