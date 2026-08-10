import Foundation
@testable import MothballCore

/// Creates a real on-disk git repo in a unique temporary directory.
/// Use in tests that need to drive `git` for real, not via a mock.
///
/// Caller is responsible for `cleanup()` in tearDown — XCTest won't
/// invoke deinit deterministically across async test methods.
final class TempGitRepo {
    let url: URL

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appending(path: "Mothball-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func git(_ args: [String], allowFailure: Bool = false) async throws -> ProcessResult {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: args,
            workingDirectory: url,
            timeout: .seconds(10)
        )
        if !allowFailure && !result.isSuccess {
            throw TestError.gitFailed(args: args, stderr: result.stderr, exit: result.exitCode)
        }
        return result
    }

    func writeFile(_ name: String, contents: String = "hello\n") throws {
        let path = url.appending(path: name)
        try contents.data(using: .utf8)!.write(to: path)
    }

    /// Common setup: init repo, configure identity, set default branch.
    /// Identity is set locally to avoid depending on the host's git config.
    func initialize() async throws {
        try await git(["init", "-q", "-b", "main"])
        try await git(["config", "user.email", "test@example.invalid"])
        try await git(["config", "user.name", "Mothball Test"])
        try await git(["config", "commit.gpgsign", "false"])
    }

    func commit(_ message: String) async throws {
        try await git(["add", "-A"])
        try await git(["commit", "-q", "-m", message])
    }

    /// Set a fake "origin" remote and a tracking branch as if we'd
    /// pushed. Doesn't actually talk to a server — we just prime local
    /// refs so `@{u}` resolves and `rev-list --count @{u}..HEAD` returns 0.
    func fakePushedOrigin(branch: String = "main") async throws {
        try await git(["remote", "add", "origin", "https://example.invalid/fake/repo.git"])
        // Create a local "remote-tracking" ref pointing at HEAD so
        // upstream resolves. This is what git fetch would have created.
        let head = try await git(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try await git(["update-ref", "refs/remotes/origin/\(branch)", head])
        try await git(["branch", "--set-upstream-to=origin/\(branch)", branch])
    }
}

enum TestError: Error, CustomStringConvertible {
    case gitFailed(args: [String], stderr: String, exit: Int32)

    var description: String {
        switch self {
        case .gitFailed(let args, let err, let code):
            return "git \(args.joined(separator: " ")) exited \(code): \(err)"
        }
    }
}
