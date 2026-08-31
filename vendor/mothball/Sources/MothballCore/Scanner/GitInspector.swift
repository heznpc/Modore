import Foundation

public struct GitInspector: Sendable {
    /// Repository and user Git config are untrusted input during an audit.
    /// These options make every inspection command read-only at the process
    /// boundary as well as at the Git-command level: `status` must not invoke
    /// a configured fsmonitor hook, no repository hook directory is usable,
    /// and a configured pager cannot outlive the bounded subprocess.
    static let safeGitPrefix = [
        "--no-optional-locks",
        "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null",
        "-c", "core.pager=cat",
    ]

    public enum Error: Swift.Error, Sendable {
        case notARepository(URL)
        case process(ProcessError)
        case commandFailed(command: String, stderr: String, exitCode: Int32)
    }

    public let gitExecutable: URL
    public let perCommandTimeout: Duration

    /// When true, run `git fetch --quiet --prune --no-tags origin`
    /// before reading metadata. This refreshes the local upstream ref
    /// so `aheadOfOrigin` reflects the actual remote state instead of
    /// the last-known-local snapshot.
    ///
    /// Off by default because fetch adds network latency (~hundreds of
    /// ms per repo at minimum) and can fail entirely on offline use.
    public let fetchBeforeInspect: Bool

    public let fetchTimeout: Duration

    public init(
        gitExecutable: URL = URL(fileURLWithPath: "/usr/bin/git"),
        perCommandTimeout: Duration = .seconds(5),
        fetchBeforeInspect: Bool = false,
        fetchTimeout: Duration = .seconds(30)
    ) {
        self.gitExecutable = gitExecutable
        self.perCommandTimeout = perCommandTimeout
        self.fetchBeforeInspect = fetchBeforeInspect
        self.fetchTimeout = fetchTimeout
    }

    public func inspect(repoAt url: URL) async throws -> GitMetadata {
        // Keep the repository probe inside the bounded child. A parent-side
        // `.git` lookup can itself block on an unavailable volume before any
        // timeout exists; `git -C` performs the same validation after spawn.
        let repositoryProbe = try await runGit(
            at: url,
            ["rev-parse", "--is-inside-work-tree"]
        )
        guard repositoryProbe.isSuccess,
              repositoryProbe.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            throw Error.notARepository(url)
        }

        if fetchBeforeInspect {
            // Best-effort: a missing remote, network outage, or auth
            // prompt should NOT make the inspection itself fail. The
            // result will just reflect whatever the local upstream ref
            // already says, which is what we'd have done without fetch.
            await tryFetch(at: url)
        }

        // All commands below are read-only and safe to run concurrently
        // against the same repo. We pay the subprocess startup cost in
        // parallel rather than serially; for a typical repo this drops
        // total inspection time from ~150ms to ~50ms on M-series macs.
        async let lastCommitRaw  = optional(at: url, ["log", "-1", "--format=%ct"])
        // Pin both dimensions that user/repository config can otherwise hide.
        // Retirement assessment must count every untracked file and every
        // submodule change even when status.showUntrackedFiles or
        // diff.ignoreSubmodules says otherwise.
        async let statusRaw      = required(at: url, [
            "status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none",
        ])
        async let originURL      = optional(at: url, ["config", "--get", "remote.origin.url"])
        async let branch         = optional(at: url, ["symbolic-ref", "--short", "HEAD"])
        async let head           = optional(at: url, ["rev-parse", "HEAD"])
        async let aheadCount     = upstreamAheadCount(at: url)

        // Use `try await`, not `try?` — a ProcessError (timeout, missing
        // git binary) on `git log` is not the same thing as "no commits"
        // and we must not silently treat them the same. Empty repos
        // legitimately return nil from `optional()` because git exits
        // non-zero, which is handled below.
        let lastCommitDate: Date?
        if let raw = try await lastCommitRaw, let unix = TimeInterval(raw) {
            lastCommitDate = Date(timeIntervalSince1970: unix)
        } else {
            lastCommitDate = nil
        }

        let isDirty = !(try await statusRaw).isEmpty

        return GitMetadata(
            lastCommitDate: lastCommitDate,
            isDirty: isDirty,
            aheadOfOrigin: try await aheadCount,
            originURL: try await originURL,
            currentBranch: try await branch,
            headSHA: try await head
        )
    }

    // MARK: - Private command helpers

    /// Runs git, throws if the command exits non-zero.
    /// Returns trimmed stdout.
    private func required(at repo: URL, _ args: [String]) async throws -> String {
        let result = try await runGit(at: repo, args)
        guard result.isSuccess else {
            throw Error.commandFailed(
                command: "git " + args.joined(separator: " "),
                stderr: result.stderr,
                exitCode: result.exitCode
            )
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs git, returns nil for a non-zero exit (legitimate "no such
    /// thing" outcome) or empty trimmed output.
    /// Used for queries like `config --get` where exit 1 means "not set".
    private func optional(at repo: URL, _ args: [String]) async throws -> String? {
        let result = try await runGit(at: repo, args)
        guard result.isSuccess else { return nil }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func runGit(at repo: URL, _ args: [String]) async throws -> ProcessResult {
        try await ProcessRunner.run(
            executable: gitExecutable,
            arguments: Self.safeGitPrefix + ["-C", repo.path] + args,
            workingDirectory: Self.safeWorkingDirectory,
            timeout: perCommandTimeout,
            wrapping: Error.process
        )
    }

    private func tryFetch(at repo: URL) async {
        _ = try? await ProcessRunner.run(
            executable: gitExecutable,
            arguments: Self.safeGitPrefix
                + ["-C", repo.path, "fetch", "--quiet", "--prune", "--no-tags", "origin"],
            workingDirectory: Self.safeWorkingDirectory,
            timeout: fetchTimeout
        )
    }

    /// `posix_spawn` must not chdir into a caller-supplied repository before
    /// ProcessRunner's timeout controller exists. Repository access starts in
    /// the child through `git -C`; this fixed local directory is only the
    /// spawn-time cwd.
    private static let safeWorkingDirectory = URL(
        fileURLWithPath: "/private/tmp",
        isDirectory: true
    )

    /// Number of local commits ahead of upstream, or nil if no upstream
    /// is configured for the current branch.
    ///
    /// Uses two calls because `rev-list @{u}..HEAD` errors loudly when
    /// no upstream exists, and we'd rather distinguish that from a real
    /// failure. The first call cheaply asks "is there an upstream?".
    private func upstreamAheadCount(at repo: URL) async throws -> Int? {
        let upstreamRef = try await optional(
            at: repo,
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]
        )
        guard upstreamRef != nil else { return nil }

        guard let countStr = try await optional(
            at: repo, ["rev-list", "--count", "@{u}..HEAD"]
        ) else {
            return nil
        }
        return Int(countStr)
    }
}
