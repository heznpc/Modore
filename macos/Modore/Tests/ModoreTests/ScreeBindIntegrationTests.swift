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

        let outcome = await ScreeService.bind(
            execution: execution, workspace: workspace, repoURL: nil
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
            execution: execution, workspace: workspace, repoURL: nil
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
        guard case .bindings(let bindings) = outcome.assessment else {
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
final class ShallowEscalationTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    /// The case worth a deep pass: a clean shallow run that found nothing.
    func test_emptyShallowRunIsWorthEscalating() {
        XCTAssertTrue(ScreeService.reportedNothingWithinShallowLimits(data("""
        {"workspace":"/w","repoUrl":null,"assessed":true,"deep":false,
         "coverage":"shallow","bindings":[]}
        """)))
    }

    /// A deep pass already looked everywhere it can. Escalating again
    /// would be an infinite regress, and its emptiness is a real finding.
    func test_emptyDeepRunIsNotEscalated() {
        XCTAssertFalse(ScreeService.reportedNothingWithinShallowLimits(data("""
        {"workspace":"/w","repoUrl":null,"assessed":true,"deep":true,
         "coverage":"deep","bindings":[]}
        """)))
    }

    /// Sessions were found; there is nothing a content scan would add,
    /// and it is the expensive pass over every candidate that already
    /// answered.
    func test_runThatFoundSessionsIsNotEscalated() {
        XCTAssertFalse(ScreeService.reportedNothingWithinShallowLimits(data("""
        {"workspace":"/w","repoUrl":null,"assessed":true,"deep":false,
         "coverage":"shallow",
         "bindings":[{"provider":"claude","sessionId":"a","source":"/s/a.jsonl",
                      "subtranscripts":[],"evidence":["working-directory"],
                      "confidence":"medium","sizeBytes":1}]}
        """)))
    }

    /// Unreadable output is schema drift, not a scan-depth problem;
    /// rerunning it deeper would just fail again more slowly.
    func test_unparseableOutputIsNotEscalated() {
        XCTAssertFalse(ScreeService.reportedNothingWithinShallowLimits(data("not json")))
    }
}
