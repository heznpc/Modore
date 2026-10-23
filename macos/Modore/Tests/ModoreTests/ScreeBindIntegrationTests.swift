import XCTest
@testable import Modore
@testable import MothballCore

/// Exercises the real subprocess path — RuntimeWorkspace resolution, the
/// pinned-script invocation, and the `-c` wrapper that works around
/// CPython refusing `/dev/fd/N` as argv[1] — rather than only the JSON
/// decoding on either side of it.
///
/// The two halves of this feature are written in different languages and
/// meet over a pipe. Unit tests on each side pass while the pipe is
/// broken, and a broken pipe fails closed: every workspace reads
/// `notAssessed`, every archive refuses, and nothing says why. So the
/// pipe gets its own test.
final class ScreeBindIntegrationTests: XCTestCase {

    /// Walks up from this source file to the repo root, which is where
    /// `scripts/scree.py` lives when the package is built from a checkout.
    private static func projectRoot(file: StaticString = #filePath) -> URL? {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("scripts/scree.py").path
            ) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private var root: URL!
    private var home: URL!
    private var execution: RuntimeExecutionContext!

    override func setUpWithError() throws {
        root = try XCTUnwrap(Self.projectRoot(), "checkout with scripts/scree.py required")
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") ||
            FileManager.default.isExecutableFile(atPath: "/usr/local/bin/python3"),
            "python3 required"
        )
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ScreeBind-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        // The execution context is injected rather than resolved from
        // `Bundle.main`. Under xctest, `Bundle.main` is the Xcode command
        // line tools directory, which the bundled-runtime branch rejects
        // for a signature it cannot validate -- a property of the test
        // host, not of the code under test. `prepareExecution` documents
        // these parameters as the injectable test boundary; this is what
        // they are for.
        execution = try XCTUnwrap(
            RuntimeWorkspace.prepareExecution(
                projectRoot: root,
                environment: ["PCH_DEVELOPMENT_MODE": "1", "PCH_PROJECT_DIR": root.path],
                resourceURL: nil
            ),
            "development-mode execution context required to reach the real binder"
        )
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    func testOriginalBackupReachesSealedScriptAndRestoresToolResults() async throws {
        let source = home.appending(path: ".claude/projects/project/session.jsonl")
        let sidecar = home.appending(path: ".claude/projects/project/session/tool-results/call.txt")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let transcript = Data(#"{"type":"user","message":{"content":"private@example.com"}}"#.utf8)
        let toolOutput = Data([0, 1, 2, 255])
        try transcript.write(to: source)
        try toolOutput.write(to: sidecar)
        let archive = home.appending(path: "session.zip")
        let created = try await ScreeService.sessionBackup(
            execution: execution,
            operation: .create(source: source.path, destination: archive), homeOverride: home
        ).get()
        XCTAssertEqual(created.status, "verified")
        XCTAssertEqual(created.fileCount, 2)
        XCTAssertEqual(Set(created.categories), ["transcript", "tool-results"])
        XCTAssertFalse(created.masked)

        let checked = try await ScreeService.sessionBackup(
            execution: execution, operation: .verify(archive)
        ).get()
        XCTAssertEqual(checked.totalBytes, Int64(transcript.count + toolOutput.count))
        let restored = home.appending(path: "new-restore")
        let receipt = try await ScreeService.sessionBackup(
            execution: execution, operation: .restore(archive: archive, destination: restored)
        ).get()
        XCTAssertEqual(receipt.status, "restored")
        let restoredSource = try XCTUnwrap(receipt.restoredSource)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: restoredSource)), transcript)
        XCTAssertEqual(try Data(contentsOf: restored.appending(
            path: ".claude/projects/project/session/tool-results/call.txt")), toolOutput)
        XCTAssertEqual(try Data(contentsOf: source), transcript)

        let again = await ScreeService.sessionBackup(
            execution: execution, operation: .restore(archive: archive, destination: restored)
        )
        guard case .failure(let error) = again else { return XCTFail("must not overwrite a restore") }
        XCTAssertTrue(error.message.contains("NEW directory"))
    }

    func testSearchPagesAllTurnsAndPreservesProviderWorkspaceScopeThroughRealProcess() async throws {
        let store = home.appending(path: ".claude/projects/-example-archive")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let lines = (0..<70).map { index in
            #"{"type":"user","uuid":"event-\#(index)","cwd":"/Users/example/archive","message":{"role":"user","content":"pagination-marker turn \#(index)"}}"#
        }.joined(separator: "\n")
        try Data(lines.utf8).write(to: store.appending(path: "archive.jsonl"))
        let other = #"{"type":"user","cwd":"/Users/example/archive-extra","message":{"role":"user","content":"pagination-marker wrong workspace"}}"#
        try Data(other.utf8).write(to: store.appending(path: "current.jsonl"))

        let first = try await ScreeService.search(
            execution: execution, query: "pagination-marker", limit: 60,
            provider: "claude", workspace: "/Users/example/archive", homeOverride: home
        ).get()
        XCTAssertEqual(first.matches.count, 60)
        XCTAssertEqual(first.hasMore, true)
        XCTAssertEqual(first.nextOffset, 60)
        XCTAssertEqual(first.totalSessions, 1)
        XCTAssertEqual(first.scope, .init(provider: "claude", workspace: "/Users/example/archive"))
        let second = try await ScreeService.search(
            execution: execution, query: "pagination-marker", limit: 60, offset: 60,
            provider: "claude", workspace: "/Users/example/archive", homeOverride: home
        ).get()
        XCTAssertEqual(second.matches.count, 10)
        XCTAssertEqual(second.hasMore, false)
        XCTAssertNil(second.nextOffset)
        XCTAssertTrue(second.isComplete)
        let combined = first.appending(second)
        XCTAssertEqual(combined.matches.count, 70)
        XCTAssertEqual(Set(combined.matches.map(\.id)).count, 70)
        XCTAssertTrue(combined.matches.allSatisfy { $0.workspace == "/Users/example/archive" })
        let otherProvider = try await ScreeService.search(
            execution: execution, query: "pagination-marker", provider: "codex", homeOverride: home
        ).get()
        XCTAssertTrue(otherProvider.matches.isEmpty)
        XCTAssertEqual(otherProvider.totalSessions, 0)
        let leftovers = try FileManager.default.contentsOfDirectory(at: execution.outputRoot, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("scree-query-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testInspectSearchHitReadsItsSourcePositionAndFollowingContext() async throws {
        let source = home.appending(path: ".claude/projects/-inspect-fixture/session.jsonl")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rows = try (0..<80).map { index in
            try JSONSerialization.data(withJSONObject: [
                "type": "user", "message": ["role": "user", "content": "visible turn \(index)"],
            ])
        }
        var data = Data()
        for row in rows { data.append(row); data.append(0x0a) }
        try data.write(to: source)
        let selected = try await ScreeService.inspect(execution: execution, source: source, turns: 20, start: 7, homeOverride: home).get()
        XCTAssertEqual(selected.windowStart, 7)
        XCTAssertEqual(selected.turns.first?.sourceIndex, 7)
        XCTAssertEqual(selected.turns.first?.text, "visible turn 7")
        XCTAssertEqual(selected.turns.last?.sourceIndex, 26)
        let recent = try await ScreeService.inspect(execution: execution, source: source, turns: 20, homeOverride: home).get()
        XCTAssertEqual(recent.windowStart, 60)
        XCTAssertEqual(recent.turns.first?.text, "visible turn 60")
    }

    func testInspectSearchHitCanReachPastTheLegacyFilePrefix() async throws {
        let source = home.appending(path: ".claude/projects/-inspect-large/session.jsonl")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        let padding = try JSONSerialization.data(withJSONObject: ["type": "progress", "data": String(repeating: "x", count: 1_024 * 1_024)]) + Data([0x0a])
        for _ in 0..<33 { try handle.write(contentsOf: padding) }
        try handle.write(contentsOf: Data(#"{"type":"user","message":{"role":"user","content":"target after 32 MiB"}}"#.utf8))
        try handle.close()
        let selected = try await ScreeService.inspect(execution: execution, source: source, start: 0, homeOverride: home).get()
        XCTAssertEqual(selected.status, .ok)
        XCTAssertEqual(selected.windowStart, 0)
        XCTAssertEqual(selected.turns.first?.text, "target after 32 MiB")
    }

    func testPinnedSearchHelperReusesDifferentQueriesAndInvalidatesChangedTranscript() async throws {
        let runtime = home.appending(path: "sealed-search-runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let identity = try XCTUnwrap(FilesystemIdentity.directory(at: runtime))
        let context = RuntimeExecutionContext(
            runtimeRoot: runtime, outputRoot: runtime,
            configurationURL: runtime.appending(path: "config.json"),
            usesBundledRuntime: true, runtimeRootIdentity: identity, outputRootIdentity: identity,
            signedBundleURL: nil,
            sealedRuntimeFiles: [
                "scripts/scree.py": try Data(contentsOf: root.appending(path: "scripts/scree.py")),
                "scripts/session_search_index.py": try Data(contentsOf: root.appending(path: "scripts/session_search_index.py")),
            ])
        // This directory contains neither script. Both imports must travel
        // through the pinned descriptors, including the optional index helper.
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.appending(path: "scripts").path))
        let store = home.appending(path: ".claude/projects/-cache-fixture")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let source = store.appending(path: "cache.jsonl")
        let original = #"{"type":"user","cwd":"/fixture/cache","message":{"role":"user","content":"oldneedle"}}"#
        try Data(original.utf8).write(to: source)
        let cold = try await ScreeService.search(
            execution: context, query: "first-absent-query", provider: "claude", homeOverride: home).get()
        let coldIndex = try XCTUnwrap(cold.index)
        XCTAssertTrue(coldIndex.enabled)
        XCTAssertEqual(coldIndex.sourceArtifactsRead, 1)
        XCTAssertEqual(coldIndex.indexedArtifacts, 1)
        XCTAssertTrue(cold.matches.isEmpty)

        let warm = try await ScreeService.search(
            execution: context, query: "different-absent-query", provider: "claude", homeOverride: home).get()
        let warmIndex = try XCTUnwrap(warm.index)
        XCTAssertEqual(warmIndex.reusedArtifacts, 1)
        XCTAssertEqual(warmIndex.skippedArtifacts, 1)
        XCTAssertEqual(warmIndex.sourceArtifactsRead, 0)
        XCTAssertTrue(warm.matches.isEmpty)

        let modifiedAt = try XCTUnwrap(try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let changed = original.replacingOccurrences(of: "oldneedle", with: "newneedle")
        XCTAssertEqual(original.utf8.count, changed.utf8.count)
        try Data(changed.utf8).write(to: source)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: source.path)
        let updated = try await ScreeService.search(
            execution: context, query: "newneedle", provider: "claude", homeOverride: home).get()
        XCTAssertEqual(updated.index?.sourceArtifactsRead, 1)
        XCTAssertEqual(updated.index?.indexedArtifacts, 1)
        XCTAssertEqual(updated.matches.first?.snippet, "newneedle")
        let verified = try await ScreeService.search(
            execution: context, query: "newneedle", provider: "claude", homeOverride: home).get()
        XCTAssertEqual(verified.index?.reusedArtifacts, 1)
        XCTAssertEqual(verified.index?.sourceArtifactsRead, 1,
                       "A cache candidate still needs verification against the original transcript")
        XCTAssertEqual(verified.matches.first?.snippet, "newneedle")
    }

    /// A workspace no session ever touched must come back as a completed
    /// assessment, not as a failure. If the wrapper is broken this returns
    /// `notAssessed` instead — same empty result, opposite meaning, and
    /// the difference is the whole feature.
    func test_bindReachesTheRealBinderAndReportsACompletedAssessment() async throws {
        let workspace = home.appending(path: "untouched", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        // `homeOverride`, not the real home: this test is about the
        // subprocess path, and the machine running it has Gemini and
        // Kiro stores that no binder reads -- which correctly makes any
        // real-home scan incomplete and would mask a broken pipe.
        let outcome = await ScreeService.bind(
            execution: execution, workspace: workspace, repoURL: nil,
            homeOverride: home
        )
        XCTAssertNil(outcome.diagnostic,
                     "a diagnostic means the binder never ran: \(outcome.diagnostic ?? "")")
        guard case .assessedNoSessions = outcome.assessment else {
            return XCTFail("""
            expected assessedNoSessions from a real binder run, got \(outcome.assessment). \
            notAssessed here means the subprocess path is broken, not that the \
            workspace has sessions.
            """)
        }
    }

    /// And the gate agrees: a genuinely session-free workspace archives.
    func test_realBinderResultUnblocksTheGate() async throws {
        let workspace = home.appending(path: "untouched2", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let outcome = await ScreeService.bind(
            execution: execution, workspace: workspace, repoURL: nil,
            homeOverride: home
        )
        XCTAssertEqual(ContinuityGate.evaluate(outcome.assessment), .allow)
    }

    /// A workspace that really does have a session must come back bound,
    /// through the same pipe. Proves the test above is not passing simply
    /// because the binder always answers "nothing".
    func test_bindFindsASessionPlantedInAFakeStore() async throws {
        let workspace = home.appending(path: "worked-in", directoryHint: .isDirectory)
        let store = home.appending(path: ".claude/projects/-fake-slug", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try Data(#"{"cwd":"\#(workspace.path)","gitBranch":"main"}\#n"#.utf8)
            .write(to: store.appending(path: "planted.jsonl"))

        // scree resolves its stores from $HOME, so the fake home is what
        // makes this hermetic rather than dependent on the machine's real
        // session history.
        let outcome = await ScreeService.bind(
            execution: execution, workspace: workspace, repoURL: nil,
            homeOverride: home
        )
        XCTAssertNil(outcome.diagnostic)
        guard case .bindings(let bindings, _) = outcome.assessment else {
            return XCTFail("expected the planted session to bind, got \(outcome.assessment)")
        }
        XCTAssertEqual(bindings.count, 1)
        XCTAssertEqual(bindings.first?.sessionID, "planted")
        XCTAssertEqual(bindings.first?.evidence, [.workingDirectory])
        XCTAssertEqual(ContinuityGate.evaluate(outcome.assessment),
                       .block(.unsealedSessions(count: 1)))
    }

    /// Locks the storage screen to the real `scree evidence` pipe. This is
    /// also the privacy regression test for the UUID query file: after the
    /// subprocess exits, no query scratch file remains in the runtime output.
    func test_evidenceReturnsFourSeparateKindsThroughTheRealSubprocess() async throws {
        let store = home.appending(
            path: ".claude/projects/-example-storage", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let transcript = """
        {"cwd":"/Users/example/work"}
        {"timestamp":"2026-08-14T00:00:00Z","message":{"role":"user","content":[{"type":"text","text":"npm cache clean 할까요?"}]}}
        {"timestamp":"2026-08-14T00:01:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"call-1","name":"Bash","input":{"command":"npm cache clean --force"}}]}}
        {"timestamp":"2026-08-14T00:01:01Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"call-1","content":"done"}]}}
        """
        try Data(transcript.utf8).write(to: store.appending(path: "storage.jsonl"))

        let support = home.appending(
            path: "Library/Application Support/Modore", directoryHint: .isDirectory
        )
        let receipts = support.appending(path: "cleanup-receipts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
        try Data("""
        version\t1
        timestamp\t2026-08-14T00:02:00Z
        status\tcomplete
        recipeId\tnpm_cache
        label\tnpm 캐시
        estimatedKB\t3400000
        reclaimedKB\t3200000
        physicalDeltaKB\t3100000
        """.utf8).write(to: receipts.appending(path: "20260814-npm.tsv"))
        try Data("2026-08-14T00:03:00Z\t24035252\t0\tnormal\n".utf8)
            .write(to: support.appending(path: "storage-samples.tsv"))

        let outcome = await ScreeService.evidence(
            execution: execution, query: "npm cache clean", homeOverride: home
        )
        let result = try outcome.get()
        XCTAssertEqual(result.conversationMentions.count, 1)
        XCTAssertEqual(result.providerToolInvocations.first?.command, "npm cache clean --force")
        XCTAssertEqual(result.providerToolInvocations.first?.status, "completed")
        XCTAssertEqual(result.modoreCleanupReceipts.first?.recipeId, "npm_cache")
        XCTAssertEqual(result.modoreCleanupReceipts.first?.reclaimedKB, 3_200_000)
        XCTAssertEqual(result.filesystemObservations.first?.freeKB, 24_035_252)

        let leftovers = try FileManager.default.contentsOfDirectory(
            at: execution.outputRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("scree-evidence-query-") }
        XCTAssertTrue(leftovers.isEmpty)
    }
}

/// The escalation rule, tested on payloads rather than through the
/// subprocess so the policy is pinned independently of scree's runtime.
///
/// The rule is coverage, not emptiness. Gating the retry on "found
/// nothing" means the moment a scan finds anything it stops looking,
/// which is the opposite of what a completeness check is for.
final class ShallowEscalationTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    private func coverage(_ json: String) -> BindingCoverage? {
        ContinuityAssessment.fromBindReport(data(json)).coverage
    }

    /// The case the old rule missed entirely: a shallow pass that found a
    /// session still has not looked where the others are.
    func test_shallowRunThatFoundSessionsIsStillIncomplete() {
        XCTAssertEqual(coverage("""
        {"workspace":"/w","repoUrl":null,"assessed":true,"deep":false,
         "coverage":"shallow",
         "bindings":[{"provider":"claude","sessionId":"a","source":"/s/a.jsonl",
                      "subtranscripts":[],"evidence":["working-directory"],
                      "confidence":"medium","sizeBytes":1}]}
        """), .shallow)
    }

    func test_emptyShallowRunIsIncomplete() {
        // Decodes to `notAssessed`, which reports no coverage at all --
        // itself a reason to escalate.
        XCTAssertNotEqual(coverage("""
        {"workspace":"/w","repoUrl":null,"assessed":true,"deep":false,
         "coverage":"shallow","bindings":[]}
        """), .complete)
    }

    func test_truncatedRunIsIncompleteEvenWithFindings() {
        XCTAssertEqual(coverage("""
        {"workspace":"/w","repoUrl":null,"assessed":true,"deep":true,
         "coverage":"truncated",
         "bindings":[{"provider":"codex","sessionId":"c","source":"/s/c.jsonl",
                      "subtranscripts":[],"evidence":["remote-url"],
                      "confidence":"high","sizeBytes":1}]}
        """), .truncated)
    }

    /// A completed pass read every byte it could; escalating again would
    /// be an infinite regress.
    func test_completeRunNeedsNoEscalation() {
        XCTAssertEqual(coverage("""
        {"workspace":"/w","repoUrl":null,"assessed":true,"deep":true,
         "coverage":"complete",
         "bindings":[{"provider":"codex","sessionId":"c","source":"/s/c.jsonl",
                      "subtranscripts":[],"evidence":["remote-url"],
                      "confidence":"high","sizeBytes":1}]}
        """), .complete)
    }

    /// Unreadable output is schema drift, not a scan-depth problem;
    /// rerunning it deeper would just fail again more slowly.
    func test_unparseableOutputIsNotAFinishedRun() {
        XCTAssertFalse(ScreeService.isWellFormed(data("not json")))
        XCTAssertTrue(ScreeService.isWellFormed(data("""
        {"workspace":"/w","repoUrl":null,"assessed":true,"deep":false,
         "coverage":"shallow","bindings":[]}
        """)))
    }
}

/// An incomplete scan is only actionable if it says which gap left it
/// short: an unreadable transcript is a permissions problem, a store with
/// no binder is a missing feature, and one message for both sends the
/// user looking for neither.
final class IncompleteScanReasonTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    func test_namesTheStoresNoBinderReads() {
        let reason = ScreeService.incompleteScanReason(data("""
        {"workspace":"/w","repoUrl":null,"assessed":true,"deep":true,
         "coverage":"truncated","bindings":[],
         "coverageDetail":{"claude":"complete","codex":"complete",
                           "unboundStores":["Gemini","Kiro"]}}
        """))
        XCTAssertTrue(reason.contains("Gemini"), reason)
        XCTAssertTrue(reason.contains("Kiro"), reason)
    }

    func test_namesTheStoreThatCouldNotBeFullyRead() {
        let reason = ScreeService.incompleteScanReason(data("""
        {"workspace":"/w","repoUrl":null,"assessed":true,"deep":true,
         "coverage":"truncated","bindings":[],
         "coverageDetail":{"claude":"incomplete","codex":"complete",
                           "unboundStores":[]}}
        """))
        XCTAssertTrue(reason.contains("Claude"), reason)
        XCTAssertFalse(reason.contains("Codex"), reason)
    }

    func test_namesClaudeDesktopWhenItsConversationStoreWasIncomplete() {
        let reason = ScreeService.incompleteScanReason(data("""
        {"workspace":"/w","repoUrl":null,"assessed":true,"deep":true,
         "coverage":"truncated","bindings":[],
         "coverageDetail":{"claude":"complete","claudeDesktop":"incomplete",
                           "codex":"complete","unboundStores":[]}}
        """))
        XCTAssertTrue(reason.contains("Claude Desktop"), reason)
        XCTAssertFalse(reason.contains("Codex"), reason)
    }

    /// A store nobody looked at outranks one that was read imperfectly:
    /// closing the second still leaves the first unexamined.
    func test_unboundStoresOutrankPartialReads() {
        let reason = ScreeService.incompleteScanReason(data("""
        {"workspace":"/w","repoUrl":null,"assessed":true,"deep":true,
         "coverage":"truncated","bindings":[],
         "coverageDetail":{"claude":"incomplete","codex":"complete",
                           "unboundStores":["Gemini"]}}
        """))
        XCTAssertTrue(reason.contains("Gemini"), reason)
    }

    func test_fallsBackToAGenericReasonWithoutDetail() {
        let reason = ScreeService.incompleteScanReason(data("""
        {"workspace":"/w","repoUrl":null,"assessed":true,"deep":true,
         "coverage":"truncated","bindings":[]}
        """))
        XCTAssertFalse(reason.isEmpty)
    }
}
