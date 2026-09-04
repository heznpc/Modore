import XCTest
@testable import Modore

private actor WorkTaskReleaseGate {
    private var isOpen = false
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func hasEntered() -> Bool { entered }

    func release() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

final class ScreeServiceTests: XCTestCase {
    func testConcurrentBindPassesUseDisjointScratchFiles() {
        let root = URL(fileURLWithPath: "/tmp/modore-bind-test", isDirectory: true)
        let first = ScreeService.bindAllScratchURLs(
            outputRoot: root,
            runID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
        let second = ScreeService.bindAllScratchURLs(
            outputRoot: root,
            runID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        )

        XCTAssertNotEqual(first.targets, second.targets)
        XCTAssertNotEqual(first.results, second.results)
        XCTAssertEqual(first.targets.deletingLastPathComponent(), root)
        XCTAssertEqual(first.results.deletingLastPathComponent(), root)
    }

    // The destination becomes a real filesystem path component under the
    // app's own results directory, so this locks down the one piece of that
    // pipeline that's pure enough to unit test without a signed runtime.
    func testPreserveFilenameCombinesToolAndSourceStem() {
        let name = ScreeService.preserveFilename(
            tool: "Claude",
            source: "/Users/test/.claude/projects/p/abc123.jsonl"
        )
        XCTAssertEqual(name, "Claude-abc123.md")
    }

    func testPreserveFilenameIgnoresSourceDirectoryComponents() {
        let name = ScreeService.preserveFilename(
            tool: "Codex",
            source: "/Users/test/.codex/sessions/2026/08/rollout-1.jsonl"
        )
        XCTAssertEqual(name, "Codex-rollout-1.md")
    }

    // tool is one of scree's own fixed labels today, but this is a filename
    // builder -- it must not trust either input to already be filesystem-safe.
    func testPreserveFilenameSanitizesUnsafeCharacters() {
        let name = ScreeService.preserveFilename(
            tool: "VS Code",
            source: "/Users/test/weird name/session file.jsonl"
        )
        XCTAssertFalse(name.contains(" "))
        XCTAssertFalse(name.contains("/"))
        XCTAssertTrue(name.hasSuffix(".md"))
    }

    // Not reachable through scree.py's own output today (source is always a
    // real Path's string form), but JsonRead.string defaults a malformed or
    // missing "source" key to "" -- the filename builder must not produce a
    // bare "-session.md"-shaped name or an empty path component in that case.
    func testPreserveFilenameFallsBackWhenSourceIsEmpty() {
        let name = ScreeService.preserveFilename(tool: "Claude", source: "")
        XCTAssertEqual(name, "Claude-session.md")
    }

    func testPrivateQueryScratchFileIsOwnerOnly() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scree-query-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(ScreeService.writePrivateQuery("private phrase", to: url))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "private phrase")
    }

    func testScratchCleanupRemovesEveryExactOldGeneratedName() throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let uuid = "11111111-2222-4333-8444-555555555555"
        let names = [
            "scree-query-\(uuid.uppercased()).txt",
            "scree-evidence-query-\(uuid.uppercased()).txt",
            "scree-sessions-\(uuid.uppercased()).json",
            "scree-bind-targets-\(uuid.lowercased()).json",
            "scree-bind-results-\(uuid.lowercased()).json",
            "scree-title-sources-\(uuid.uppercased()).json",
            "scree-inspect-sources-\(uuid.lowercased()).json",
        ]
        for name in names {
            try writeScratch(name, in: root, modifiedAt: now.addingTimeInterval(-7_200))
        }

        let removed = ScreeService.cleanupStaleScratchFiles(
            in: root,
            now: now,
            minimumAge: 3_600
        )

        XCTAssertEqual(removed, names.count)
        for name in names {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: root.appendingPathComponent(name).path
            ))
        }
    }

    func testScratchCleanupPreservesNamesTypesAndLinksItDoesNotOwn() throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = now.addingTimeInterval(-7_200)
        let uuid = "11111111-2222-4333-8444-555555555555"
        let preservedNames = [
            "scree-query-not-a-uuid.txt",
            "scree-query-\(uuid).json",
            "scree-query-\(uuid).txt.bak",
            "scree-query-extra-\(uuid).txt",
            "scree-query-11111111-2222-4333-8444-aAaAaAaAaAaA.txt",
        ]
        for name in preservedNames {
            try writeScratch(name, in: root, modifiedAt: old)
        }

        let directoryName = "scree-sessions-\(uuid).json"
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: directory.path)

        let hardLinkSource = root.appendingPathComponent("hard-link-source")
        try Data("keep".utf8).write(to: hardLinkSource)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: hardLinkSource.path)
        let hardLinkName = "scree-bind-results-\(uuid).json"
        let hardLink = root.appendingPathComponent(hardLinkName)
        try FileManager.default.linkItem(at: hardLinkSource, to: hardLink)

        XCTAssertEqual(ScreeService.cleanupStaleScratchFiles(
            in: root, now: now, minimumAge: 3_600
        ), 0)
        for name in preservedNames + [directoryName, hardLinkName] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: root.appendingPathComponent(name).path
            ))
        }
    }

    func testScratchCleanupPreservesYoungExactFile() throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let name = "scree-query-11111111-2222-4333-8444-555555555555.txt"
        try writeScratch(name, in: root, modifiedAt: now.addingTimeInterval(-300))

        XCTAssertEqual(ScreeService.cleanupStaleScratchFiles(
            in: root, now: now, minimumAge: 3_600
        ), 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(name).path
        ))
    }

    func testScratchCleanupNeverFollowsMatchingSymlink() throws {
        let root = try makeScratchRoot()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratch-cleanup-outside-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("user file".utf8).write(to: outside)
        let name = "scree-sessions-11111111-2222-4333-8444-555555555555.json"
        let link = root.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertEqual(ScreeService.cleanupStaleScratchFiles(
            in: root,
            now: Date(timeIntervalSince1970: 2_000_000_000),
            minimumAge: 0
        ), 0)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), outside.path)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "user file")
    }

    func testScratchCleanupPreservesReplacementInstalledBeforeFinalValidation() throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = now.addingTimeInterval(-7_200)
        let name = "scree-bind-targets-11111111-2222-4333-8444-555555555555.json"
        let candidate = try writeScratch(name, in: root, modifiedAt: old, contents: "stale")
        let replacement = try writeScratch(
            "replacement", in: root, modifiedAt: old, contents: "user replacement"
        )
        var replaced = false

        let removed = ScreeService.cleanupStaleScratchFiles(
            in: root,
            now: now,
            minimumAge: 3_600,
            beforeFinalValidation: { path in
                guard path == candidate, !replaced else { return }
                replaced = true
                try? FileManager.default.removeItem(at: candidate)
                try? FileManager.default.moveItem(at: replacement, to: candidate)
            }
        )

        XCTAssertTrue(replaced)
        XCTAssertEqual(removed, 0)
        XCTAssertEqual(try String(contentsOf: candidate, encoding: .utf8), "user replacement")
    }

    func testScratchCleanupStopsWhenDirectoryNameChangesIdentity() throws {
        let root = try makeScratchRoot()
        let moved = root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)-moved", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: moved)
        }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let name = "scree-evidence-query-11111111-2222-4333-8444-555555555555.txt"
        _ = try writeScratch(name, in: root, modifiedAt: now.addingTimeInterval(-7_200))
        var swapped = false

        let removed = ScreeService.cleanupStaleScratchFiles(
            in: root,
            now: now,
            minimumAge: 3_600,
            beforeFinalValidation: { _ in
                guard !swapped else { return }
                swapped = true
                try? FileManager.default.moveItem(at: root, to: moved)
                try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: root.path
                )
            }
        )

        XCTAssertTrue(swapped)
        XCTAssertEqual(removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: moved.appendingPathComponent(name).path
        ))
    }

    private func makeScratchRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreeScratchCleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: root.path
        )
        return root
    }

    @discardableResult
    private func writeScratch(
        _ name: String,
        in root: URL,
        modifiedAt: Date,
        contents: String = "scratch"
    ) throws -> URL {
        let file = root.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600, .modificationDate: modifiedAt],
            ofItemAtPath: file.path
        )
        return file
    }

    func testSignedAppUsesOnlyItsEmbeddedPython() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SignedPython-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent(
            "Contents/Resources/modore-python/bin/python3.11"
        )
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("helper".utf8).write(to: helper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helper.path
        )

        XCTAssertEqual(
            ScreeService.python3Path(
                signedBundleURL: root,
                developmentCandidates: ["/bin/sh"]
            ),
            helper.path
        )
    }

    func testDamagedSignedAppNeverFallsBackToSystemPython() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MissingSignedPython-\(UUID().uuidString)")
        XCTAssertNil(ScreeService.python3Path(
            signedBundleURL: root,
            developmentCandidates: ["/bin/sh"]
        ))
    }

    func testSignedAppRejectsSymlinkedPythonHelper() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkedPython-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent(
            "Contents/Resources/modore-python/bin/python3.11"
        )
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: helper.path, withDestinationPath: "/bin/sh")

        XCTAssertNil(ScreeService.python3Path(
            signedBundleURL: root,
            developmentCandidates: ["/bin/sh"]
        ))
    }

    func testPreserveUsesTheCreateOnlyPathReturnedByScree() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreserveOutput-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let actual = parent.appendingPathComponent("Claude-session-0123456789abcdef.md")
        try Data("masked".utf8).write(to: actual)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: actual.path
        )
        let payload = try JSONSerialization.data(withJSONObject: [
            "status": "preserved",
            "output": actual.path,
            "masked": true,
        ])

        XCTAssertEqual(
            ScreeService.validatedPreserveOutput(
                String(decoding: payload, as: UTF8.self),
                expectedParent: parent
            ),
            actual
        )
    }

    func testPreserveRejectsAPathOutsideItsOutputDirectory() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreserveParent-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreserveOutside-\(UUID().uuidString).md")
        defer {
            try? FileManager.default.removeItem(at: parent)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("masked".utf8).write(to: outside)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: outside.path
        )
        let payload = try JSONSerialization.data(withJSONObject: [
            "status": "preserved",
            "output": outside.path,
            "masked": true,
        ])

        XCTAssertNil(ScreeService.validatedPreserveOutput(
            String(decoding: payload, as: UTF8.self),
            expectedParent: parent
        ))
    }
}

@MainActor
final class WorkScreenTaskLifecycleTests: XCTestCase {
    private func settleStartup(_ model: ScanModel) async {
        let tasks = model.cancelTrackedApplicationTasks()
        for task in tasks { await task.value }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testNewestAuditRequestWinsAfterOlderRequestIsCancelled() async {
        let model = ScanModel(automaticallyScansStaleResults: false)
        model.refreshScreeReport(using: {
            try? await Task.sleep(nanoseconds: 500_000_000)
            return .failure("stale result")
        })
        model.refreshScreeReport(using: { .failure("new result") })

        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(model.screeError, "new result")
        XCTAssertFalse(model.screeNeedsRefresh)
        XCTAssertFalse(model.screeLoading)
        XCTAssertNil(model.screeTask)
    }

    func testSuccessfulAuditRefreshInvalidatesRepoJudgmentAndAdvancesRevision() async throws {
        let model = ScanModel(automaticallyScansStaleResults: false)
        await settleStartup(model)
        model.archiveBindingComplete = true
        model.archiveError = "old archive error"
        model.repoScanFailures = ["/old": "old failure"]
        model.reposNotScanned = ["/old-unscanned"]
        model.archiveInspectionFailures = 2
        let revision = model.screeReportRevision
        let report = try XCTUnwrap(ScreeReport(json: ["worktrees": ["items": []]]))

        model.refreshScreeReport(using: { .success(report) })
        await waitUntil { model.screeTask == nil }

        XCTAssertEqual(model.screeReportRevision, revision + 1)
        XCTAssertFalse(model.archiveBindingComplete)
        XCTAssertNil(model.archiveError)
        XCTAssertNil(model.repoAssessments)
        XCTAssertTrue(model.repoScanFailures.isEmpty)
        XCTAssertTrue(model.reposNotScanned.isEmpty)
        XCTAssertEqual(model.archiveInspectionFailures, 0)
    }

    func testNewestSessionIndexRequestWinsAfterOlderRequestIsCancelled() async {
        let model = ScanModel(automaticallyScansStaleResults: false)
        let old = SessionIndex(total: 1, sessions: [])
        let newest = SessionIndex(total: 7, sessions: [])
        model.refreshSessionIndex(using: {
            try? await Task.sleep(nanoseconds: 500_000_000)
            return .success(old)
        })
        model.refreshSessionIndex(using: { .success(newest) })

        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(model.sessionIndex, newest)
        XCTAssertFalse(model.sessionIndexNeedsRefresh)
        XCTAssertFalse(model.sessionIndexLoading)
        XCTAssertNil(model.sessionIndexTask)
    }

    func testSupersededLoaderRemainsOwnedUntilItsDrainCompletes() async {
        let model = ScanModel(automaticallyScansStaleResults: false)
        await settleStartup(model)
        let gate = WorkTaskReleaseGate()
        model.refreshSessionIndex(using: {
            await gate.wait()
            return .success(SessionIndex(total: 1, sessions: []))
        })
        let superseded = model.sessionIndexTask
        for _ in 0..<100 {
            if await gate.hasEntered() { break }
            await Task.yield()
        }

        model.refreshSessionIndex(using: {
            .success(SessionIndex(total: 2, sessions: []))
        })

        XCTAssertTrue(superseded?.isCancelled == true)
        XCTAssertFalse(model.pendingDrainTasks.isEmpty)
        var terminationReplies = 0
        XCTAssertTrue(model.cancelApplicationTasksForTermination {
            terminationReplies += 1
        })
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(terminationReplies, 0)

        await gate.release()
        await waitUntil { terminationReplies > 0 }
        XCTAssertEqual(terminationReplies, 1)
    }

    func testLeavingWorkScreenCancelsAutomaticLoadersAndInvalidatesResults() {
        let model = ScanModel(automaticallyScansStaleResults: false)
        model.refreshScreeReport(using: {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            return .failure("must not land")
        })
        model.refreshSessionIndex(using: {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            return .success(SessionIndex(total: 99, sessions: []))
        })
        model.refreshArchiveCandidates(
            using: {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return RepoScanOutcome(
                    candidates: [],
                    failures: ["/must-not-land": "cancelled"],
                    notScanned: []
                )
            },
            binding: { $0 }
        )
        model.contentSearchRunning = true
        model.contentSearchTask = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
        model.titleRequests = ["/tmp/title.jsonl"]
        model.conversationLoads["loading"] = .loading
        model.conversationLoads["finished"] = .failed("kept")
        let auditGeneration = model.screeGeneration
        let indexGeneration = model.sessionIndexGeneration
        let archiveGeneration = model.archiveGeneration
        let contentGeneration = model.contentSearchGeneration

        model.cancelWorkScreenTasks()

        XCTAssertGreaterThan(model.screeGeneration, auditGeneration)
        XCTAssertGreaterThan(model.sessionIndexGeneration, indexGeneration)
        XCTAssertGreaterThan(model.archiveGeneration, archiveGeneration)
        XCTAssertGreaterThan(model.contentSearchGeneration, contentGeneration)
        XCTAssertFalse(model.screeLoading)
        XCTAssertFalse(model.sessionIndexLoading)
        XCTAssertTrue(model.screeNeedsRefresh)
        XCTAssertTrue(model.sessionIndexNeedsRefresh)
        XCTAssertFalse(model.archiveLoading)
        XCTAssertFalse(model.contentSearchRunning)
        XCTAssertNil(model.screeTask)
        XCTAssertNil(model.sessionIndexTask)
        XCTAssertNil(model.archiveTask)
        XCTAssertNil(model.contentSearchTask)
        XCTAssertFalse(model.pendingDrainTasks.isEmpty)
        XCTAssertTrue(model.titleRequests.isEmpty)
        XCTAssertNil(model.conversationLoads["loading"])
        XCTAssertEqual(model.conversationLoads["finished"], .failed("kept"))
        XCTAssertTrue(model.repoScanFailures.isEmpty)
    }

    func testLeavingWorkAfterCompletedBindingKeepsItsCompletionState() {
        let model = ScanModel(automaticallyScansStaleResults: false)
        model.archiveBindingComplete = true
        XCTAssertNil(model.archiveTask)

        model.cancelWorkScreenTasks()

        XCTAssertTrue(model.archiveBindingComplete)
    }

    func testCancelledRefreshKeepsPriorResultsMarkedForRefreshOnReentry() {
        let model = ScanModel(automaticallyScansStaleResults: false)
        model.sessionIndex = SessionIndex(total: 1, sessions: [])
        model.sessionIndexNeedsRefresh = false
        model.screeNeedsRefresh = false
        model.refreshSessionIndex(using: {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            return .success(SessionIndex(total: 2, sessions: []))
        })
        model.refreshScreeReport(using: {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            return .failure("must not land")
        })

        model.cancelWorkScreenTasks()

        XCTAssertTrue(model.sessionIndexNeedsRefresh)
        XCTAssertTrue(model.screeNeedsRefresh)
        XCTAssertEqual(model.sessionIndex?.total, 1)
    }

    func testQuitAfterScreenCancellationStillAwaitsPendingDrain() async {
        let model = ScanModel(automaticallyScansStaleResults: false)
        await settleStartup(model)
        let gate = WorkTaskReleaseGate()
        let search = Task<Void, Never> { await gate.wait() }
        model.contentSearchTask = search
        model.contentSearchRunning = true
        for _ in 0..<100 {
            if await gate.hasEntered() { break }
            await Task.yield()
        }

        model.cancelWorkScreenTasks()
        XCTAssertTrue(search.isCancelled)
        XCTAssertNil(model.contentSearchTask)
        XCTAssertFalse(model.pendingDrainTasks.isEmpty)

        var terminationReplies = 0
        XCTAssertTrue(model.cancelApplicationTasksForTermination {
            terminationReplies += 1
        })
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(terminationReplies, 0)

        await gate.release()
        await waitUntil { terminationReplies > 0 }
        XCTAssertEqual(terminationReplies, 1)
    }

    func testLeavingStorageScreenCancelsEvidenceSearch() {
        let model = ScanModel(automaticallyScansStaleResults: false)
        let task = Task<Void, Never> {
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { }
        }
        model.storageEvidenceTask = task
        model.storageEvidenceRunning = true
        let generation = model.storageEvidenceGeneration

        model.cancelStorageEvidenceSearch()

        XCTAssertTrue(task.isCancelled)
        XCTAssertGreaterThan(model.storageEvidenceGeneration, generation)
        XCTAssertFalse(model.storageEvidenceRunning)
        XCTAssertNil(model.storageEvidenceTask)
    }

    func testLateCancelledConversationCannotClearNewerState() {
        let model = ScanModel(automaticallyScansStaleResults: false)
        let oldToken = UUID()
        let newToken = UUID()
        model.conversationLoadTokens["same"] = newToken
        model.conversationLoads["same"] = .failed("new result")

        XCTAssertFalse(model.finishConversationLoad(
            key: "same",
            token: oldToken,
            state: nil
        ))
        XCTAssertEqual(model.conversationLoads["same"], .failed("new result"))
        XCTAssertEqual(model.conversationLoadTokens["same"], newToken)
    }

    func testLateTitleRequestCannotReleaseNewerRequestToken() {
        let model = ScanModel(automaticallyScansStaleResults: false)
        let source = "/tmp/same.jsonl"
        let oldToken = UUID()
        let newToken = UUID()
        model.titleRequests.insert(source)
        model.sessionTitleRequestTokens[source] = newToken

        model.finishSessionTitleRequest(
            sources: [source],
            token: oldToken,
            fetched: [:],
            cancelled: true
        )

        XCTAssertTrue(model.titleRequests.contains(source))
        XCTAssertEqual(model.sessionTitleRequestTokens[source], newToken)
    }

    func testSearchHitOutsideOlderIndexRemainsAvailableToDetailPane() {
        let model = ScanModel(automaticallyScansStaleResults: false)
        model.sessionIndex = SessionIndex(total: 0, sessions: [])
        let match = SessionSearchMatch(
            source: "/tmp/new-after-index.jsonl",
            tool: "Codex",
            workspace: "/tmp/project",
            lastActive: "2026-08-30 22:00",
            lastActiveEpoch: nil,
            at: nil,
            eventId: nil,
            index: 1,
            role: "user",
            isUser: true,
            snippet: "new work"
        )
        model.selectedSearchMatch = match
        model.selectedSessionSource = match.source

        XCTAssertEqual(model.selectedSearchMatchForDetail, match)
        model.selectedSessionSource = "/tmp/another.jsonl"
        XCTAssertNil(model.selectedSearchMatchForDetail)
    }

    func testNewestRepositoryAuditRequestWinsAfterOlderRequestIsCancelled() async {
        let model = ScanModel(automaticallyScansStaleResults: false)
        model.refreshArchiveCandidates(
            using: {
                try? await Task.sleep(nanoseconds: 500_000_000)
                return RepoScanOutcome(
                    candidates: [],
                    failures: ["/stale": "must not land"],
                    notScanned: []
                )
            },
            binding: { $0 }
        )
        model.refreshArchiveCandidates(
            using: {
                RepoScanOutcome(
                    candidates: [],
                    failures: ["/newest": "visible"],
                    notScanned: []
                )
            },
            binding: { $0 }
        )

        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(model.repoScanFailures, ["/newest": "visible"])
        XCTAssertFalse(model.archiveLoading)
        XCTAssertNil(model.archiveTask)
    }

    func testApplicationTerminationWaitsForRawTransferCleanup() async {
        let model = ScanModel(automaticallyScansStaleResults: false)
        await settleStartup(model)
        let gate = WorkTaskReleaseGate()
        var sheetCompletions = 0
        model.startSessionBackup(
            using: {
                await gate.wait()
                return .failure(.init(message: "cancelled test transfer"))
            },
            completion: { _ in sheetCompletions += 1 }
        )
        for _ in 0..<100 {
            if await gate.hasEntered() { break }
            await Task.yield()
        }
        let didEnter = await gate.hasEntered()
        XCTAssertTrue(didEnter)

        var terminationReplies = 0
        XCTAssertTrue(model.cancelApplicationTasksForTermination {
            terminationReplies += 1
        })
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(terminationReplies, 0)

        await gate.release()
        await waitUntil { terminationReplies > 0 }

        XCTAssertEqual(terminationReplies, 1)
        XCTAssertEqual(sheetCompletions, 0)
        XCTAssertNil(model.sessionBackupTask)
        XCTAssertNil(model.applicationTerminationWaitTask)
        XCTAssertNil(model.applicationTerminationDeadlineTask)
    }

    func testMaskedExportHasOneOwnerAndTerminationWaitsForIt() async {
        let model = ScanModel(automaticallyScansStaleResults: false)
        await settleStartup(model)
        let gate = WorkTaskReleaseGate()
        var firstCompletions = 0
        var secondFailure: String?
        model.startSessionExport(
            source: "/tmp/first.jsonl",
            using: {
                await gate.wait()
                return .failure("cancelled export")
            },
            completion: { _ in firstCompletions += 1 }
        )
        for _ in 0..<100 {
            if await gate.hasEntered() { break }
            await Task.yield()
        }
        model.startSessionExport(
            source: "/tmp/second.jsonl",
            using: { .failure("must not run") },
            completion: { outcome in
                if case .failure(let message) = outcome { secondFailure = message }
            }
        )
        XCTAssertEqual(secondFailure, "다른 대화 내보내기가 진행 중입니다.")

        var terminationReplies = 0
        XCTAssertTrue(model.cancelApplicationTasksForTermination {
            terminationReplies += 1
        })
        XCTAssertNil(model.sessionExportTask)
        XCTAssertNil(model.screePreserveInFlightSource)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(terminationReplies, 0)

        await gate.release()
        await waitUntil { terminationReplies > 0 }
        XCTAssertEqual(terminationReplies, 1)
        XCTAssertEqual(firstCompletions, 0)
    }

    func testApplicationTerminationDoesNotDeferWithoutOwnedTasks() async {
        let model = ScanModel(automaticallyScansStaleResults: false)
        let startupTasks = model.cancelTrackedApplicationTasks()
        for task in startupTasks { await task.value }
        var terminationReplies = 0

        XCTAssertFalse(model.cancelApplicationTasksForTermination {
            terminationReplies += 1
        })
        XCTAssertEqual(terminationReplies, 0)
        XCTAssertTrue(model.applicationTerminationStarted)
        model.runScan()
        XCTAssertEqual(model.state, .idle)
    }

    func testApplicationTerminationCancelsAndWaitsForDeepScan() async {
        let model = ScanModel(automaticallyScansStaleResults: false)
        await settleStartup(model)
        let gate = WorkTaskReleaseGate()
        let scan = Task { await gate.wait() }
        model.scanTask = scan
        model.state = .running
        for _ in 0..<100 {
            if await gate.hasEntered() { break }
            await Task.yield()
        }
        let didEnter = await gate.hasEntered()
        XCTAssertTrue(didEnter)

        var terminationReplies = 0
        XCTAssertTrue(model.cancelApplicationTasksForTermination {
            terminationReplies += 1
        })
        XCTAssertTrue(scan.isCancelled)
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.scanTask)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(terminationReplies, 0)

        await gate.release()
        await waitUntil { terminationReplies > 0 }
        XCTAssertEqual(terminationReplies, 1)
    }

    func testLateCancelledObservationCannotOverwriteNewerRun() async {
        let model = ScanModel(automaticallyScansStaleResults: false)
        for task in model.cancelTrackedApplicationTasks() { await task.value }
        XCTAssertFalse(model.isBusy)

        let gate = WorkTaskReleaseGate()
        model.observeNow(windowSeconds: 10, using: {
            await gate.wait()
            return .failure("stale observation")
        })
        for _ in 0..<100 {
            if await gate.hasEntered() { break }
            await Task.yield()
        }
        model.cancelActivityScreenTasks()
        model.observeNow(windowSeconds: 30, using: {
            .ready(ObservationResult(
                windowSeconds: 30,
                processRows: [],
                newConnectionRows: [],
                networkUnavailable: false
            ))
        })
        for _ in 0..<100 {
            if model.observationResult?.windowSeconds == 30 { break }
            await Task.yield()
        }

        XCTAssertEqual(model.observationResult?.windowSeconds, 30)
        XCTAssertNil(model.observationErrorMessage)
        XCTAssertFalse(model.observationInFlight)

        await gate.release()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(model.observationResult?.windowSeconds, 30)
        XCTAssertNil(model.observationErrorMessage)
        XCTAssertFalse(model.observationInFlight)
    }
}

final class ScreeEvidenceResultTests: XCTestCase {
    private func decode(
        definitive: Bool,
        coverage: String = "complete",
        reason: String? = nil
    ) throws
        -> ScreeEvidenceResult {
        let scanned = definitive ? 20 : 12
        let unreadable = definitive ? 0 : 2
        let truncatedReason = reason ?? (coverage == "complete" ? nil : "time")
        let json = """
        {"query":"DerivedData","conversationMentions":[],
         "providerToolInvocations":[],"modoreCleanupReceipts":[],
         "filesystemObservations":[],"scannedSessions":\(scanned),"totalSessions":20,
         "unreadableSessions":\(unreadable),"coverage":"\(coverage)",
         "truncatedReason":\(truncatedReason.map { "\"\($0)\"" } ?? "null"),
         "definitive":\(definitive),"masked":true}
        """
        return try JSONDecoder().decode(ScreeEvidenceResult.self, from: Data(json.utf8))
    }

    func testFourKindsKeepTheirRequiredNaturalLanguageLabels() {
        XCTAssertEqual(
            ScreeEvidenceKind.allCases.map(\.label),
            ["언급됨", "Provider 도구 기록", "Modore 조치 기록", "후속 변화 관찰됨"]
        )
    }

    func testIncompleteEvidenceDoesNotTurnUnknownIntoNone() throws {
        let result = try decode(definitive: false, coverage: "truncated")
        XCTAssertFalse(result.matchSummary.contains("없습니다"))
        let note = try XCTUnwrap(result.coverageNote)
        XCTAssertTrue(note.contains("단정하지 않습니다"))
        XCTAssertTrue(note.contains("12/20"))
        XCTAssertTrue(note.contains("2"))
    }

    func testDiscoveryFailureNamesTheStoreInsteadOfAResultLimit() throws {
        let result = try decode(
            definitive: false,
            coverage: "truncated",
            reason: "discovery"
        )
        let note = try XCTUnwrap(result.coverageNote)
        XCTAssertTrue(note.contains("저장소"))
        XCTAssertFalse(note.contains("결과 제한"))
    }

    func testOnlyDefinitivePayloadMayStateNoMatchingRecord() throws {
        let result = try decode(definitive: true)
        XCTAssertTrue(result.matchSummary.contains("찾지 못했습니다"))
        XCTAssertNil(result.coverageNote)
    }

    /// Query hits use their own event time, while query-independent storage
    /// records remain in a separate context list.
    func testTimelineUsesTurnTimestampAndSeparatesQueryMatchesFromContext() throws {
        let json = """
        {"query":"storage","conversationMentions":[
          {"source":"/Users/example/session.jsonl","tool":"Claude",
           "workspace":"/Users/example/work","lastActive":"2026-08-24 18:30",
           "lastActiveEpoch":1787563800,"at":"2026-08-24T09:30:00Z",
           "eventId":"turn-1","index":1,"role":"user",
           "isUser":true,"snippet":"storage"}],
         "providerToolInvocations":[
          {"kind":"provider_tool_invocation","command":"du -sh .","at":"2026-08-24T09:40:00.500Z",
           "callId":"call-1","status":"completed",
           "tool":"Codex","source":"/Users/example/tool.jsonl","workspace":"/Users/example/work",
           "lastActive":"2026-08-24 18:41","lastActiveEpoch":1787564460}],
         "modoreCleanupReceipts":[],
         "filesystemObservations":[
          {"kind":"filesystem_observation","at":"2026-08-24T09:45:00Z",
           "freeKB":1000,"dropKB":0,"status":"normal"}],
         "scannedSessions":1,"totalSessions":1,"unreadableSessions":0,
         "coverage":"complete","truncatedReason":null,"definitive":true,"masked":true}
        """
        let result = try JSONDecoder().decode(ScreeEvidenceResult.self, from: Data(json.utf8))
        let queryItems = StorageEvidenceTimelineItem.queryItems(from: result)
        let contextItems = StorageEvidenceTimelineItem.contextItems(from: result)

        XCTAssertEqual(
            queryItems.map(\.evidenceLabel),
            ["실행 완료 기록", "언급됨"]
        )
        XCTAssertEqual(queryItems[0].occurredAt, Date(timeIntervalSince1970: 1_787_564_400.5))
        XCTAssertEqual(queryItems[1].occurredAt, Date(timeIntervalSince1970: 1_787_563_800))
        XCTAssertEqual(contextItems.map(\.evidenceLabel), ["후속 변화 관찰됨"])
    }

    func testTimelineKeepsMalformedTimesExplicitlyUnknownAndLast() throws {
        let json = """
        {"query":"storage","conversationMentions":[],"providerToolInvocations":[],
         "modoreCleanupReceipts":[
          {"kind":"modore_cleanup_receipt","at":"not-a-date","recipeId":"cache",
           "label":"cache","status":"complete","estimatedKB":null}],
         "filesystemObservations":[
          {"kind":"filesystem_observation","at":"2026-08-24T09:45:00Z",
           "freeKB":1000,"dropKB":0,"status":"normal"}],
         "scannedSessions":0,"totalSessions":0,"unreadableSessions":0,
         "coverage":"complete","truncatedReason":null,"definitive":true,"masked":true}
        """
        let result = try JSONDecoder().decode(ScreeEvidenceResult.self, from: Data(json.utf8))
        let items = StorageEvidenceTimelineItem.contextItems(from: result)

        XCTAssertNotNil(items.first?.occurredAt)
        XCTAssertNil(items.last?.occurredAt)
        XCTAssertEqual(items.last?.displayTime, "시각 확인 안 됨")
    }

    func testConversationHitNeverFallsBackToResumedSessionTime() throws {
        let json = """
        {"query":"storage","conversationMentions":[
          {"source":"/Users/example/session.jsonl","tool":"Claude",
           "workspace":"/Users/example/work","lastActive":"2026-08-24 18:30",
           "lastActiveEpoch":1787563800,"at":null,"eventId":null,
           "index":1,"role":"user","isUser":true,"snippet":"storage"}],
         "providerToolInvocations":[],"modoreCleanupReceipts":[],
         "filesystemObservations":[],"scannedSessions":1,"totalSessions":1,
         "unreadableSessions":0,"coverage":"complete","truncatedReason":null,
         "definitive":true,"masked":true}
        """
        let result = try JSONDecoder().decode(ScreeEvidenceResult.self, from: Data(json.utf8))
        let item = try XCTUnwrap(StorageEvidenceTimelineItem.queryItems(from: result).first)
        XCTAssertNil(item.occurredAt)
        XCTAssertEqual(item.displayTime, "시각 확인 안 됨")
    }

    func testBlockedReceiptIsNeutralAndKeepsMeasuredAmountsSeparate() throws {
        let json = """
        {"query":"storage","conversationMentions":[],"providerToolInvocations":[],
         "modoreCleanupReceipts":[
          {"kind":"modore_cleanup_receipt","at":"2026-08-24T09:45:00Z",
           "recipeId":"cache","label":"캐시","status":"blocked",
           "estimatedKB":3000,"reclaimedKB":0,"physicalDeltaKB":0}],
         "filesystemObservations":[],"scannedSessions":0,"totalSessions":0,
         "unreadableSessions":0,"coverage":"complete","truncatedReason":null,
         "definitive":true,"masked":true}
        """
        let result = try JSONDecoder().decode(ScreeEvidenceResult.self, from: Data(json.utf8))
        let item = try XCTUnwrap(StorageEvidenceTimelineItem.contextItems(from: result).first)
        XCTAssertEqual(item.evidenceLabel, "Modore 조치 기록")
        XCTAssertTrue(item.detail.contains("실행 차단"))
        XCTAssertTrue(item.detail.contains("회수 기록"))
        XCTAssertTrue(item.detail.contains("가용 공간 변화"))
        XCTAssertTrue(item.detail.contains("사전 추정"))
    }
}
