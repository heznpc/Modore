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
