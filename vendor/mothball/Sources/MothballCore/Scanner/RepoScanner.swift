import Foundation

public struct ScanReport: Sendable, Equatable {
    public let repos: [RepoInfo]
    public let failures: [ScanFailure]

    public init(repos: [RepoInfo], failures: [ScanFailure]) {
        self.repos = repos
        self.failures = failures
    }
}

public struct ScanFailure: Identifiable, Sendable, Hashable {
    public let path: URL
    public let reason: String

    public var id: URL { path }

    public init(path: URL, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct RepoScanner: Sendable {
    public let inspector: GitInspector

    /// Directory names that we never descend into. They are typically
    /// massive and contain bundled `.git` directories from third-party
    /// packages, which would otherwise drown the result list and slow
    /// the scan to a crawl.
    public static let defaultPrunedNames: Set<String> = [
        "node_modules", ".venv", "venv", "env",
        ".tox", "__pycache__",
        "target", "build", ".build",
        "DerivedData", ".gradle",
        "Pods", ".bundle",
    ]

    public let prunedDirectoryNames: Set<String>
    public let maxConcurrentInspections: Int

    public init(
        inspector: GitInspector = GitInspector(),
        prunedDirectoryNames: Set<String> = defaultPrunedNames,
        maxConcurrentInspections: Int = 8
    ) {
        self.inspector = inspector
        self.prunedDirectoryNames = prunedDirectoryNames
        self.maxConcurrentInspections = maxConcurrentInspections
    }

    /// Walks `roots` looking for git repositories, then inspects each
    /// in parallel (bounded by `maxConcurrentInspections`).
    ///
    public func scan(roots: [URL]) async -> [RepoInfo] {
        await scanReport(roots: roots).repos
    }

    /// Walks `roots` looking for git repositories, then inspects each
    /// in parallel (bounded by `maxConcurrentInspections`).
    ///
    /// Repos that fail inspection (corrupt .git, permission denied, timeout,
    /// etc.) are returned as failures so callers do not accidentally present
    /// "nothing found" when the truth is "found, but could not inspect."
    public func scanReport(roots: [URL]) async -> ScanReport {
        var discovered: [URL] = []
        for root in roots {
            findRepositories(under: root, into: &discovered)
        }

        // Bounded-concurrency pattern: seed the group with `limit` tasks,
        // then for every completion add one more from the iterator. The
        // group's natural backpressure keeps at most `limit` tasks in
        // flight without needing a hand-rolled counter.
        return await withTaskGroup(of: InspectionOutcome.self) { group in
            var iterator = discovered.makeIterator()

            for _ in 0..<maxConcurrentInspections {
                guard let next = iterator.next() else { break }
                let repoURL = next
                group.addTask { await self.inspect(at: repoURL) }
            }

            var results: [RepoInfo] = []
            var failures: [ScanFailure] = []
            while let value = await group.next() {
                switch value {
                case .success(let info):
                    results.append(info)
                case .failure(let failure):
                    failures.append(failure)
                }
                if let next = iterator.next() {
                    let repoURL = next
                    group.addTask { await self.inspect(at: repoURL) }
                }
            }
            return ScanReport(repos: results, failures: failures)
        }
    }

    // MARK: - Discovery

    /// Recursive walk that prunes at git repo boundaries and at known
    /// noise directories. Recursive (not enumerator-based) so we can
    /// stop descending the moment we find a `.git` — avoids walking
    /// millions of files inside vendored dependencies.
    private func findRepositories(under root: URL, into found: inout [URL]) {
        let fm = FileManager.default

        // Don't follow symlinks. They're rare in project trees and a
        // symlink loop would hang the scan.
        let attrs = try? fm.attributesOfItem(atPath: root.path)
        if (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink {
            return
        }

        let gitDir = root.appending(path: ".git")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: gitDir.path, isDirectory: &isDir) {
            // .git can also be a regular file (worktrees, submodules
            // pointing to the real gitdir elsewhere). Both are repos.
            found.append(root)
            return
        }

        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []  // .skipsHiddenFiles NOT set: we need to see dotfiles
        ) else {
            return  // permission denied, or root went away mid-scan
        }

        for entry in entries {
            let name = entry.lastPathComponent
            if prunedDirectoryNames.contains(name) { continue }
            // Hidden dirs other than .git are mostly tooling/cache dirs
            // (.idea, .vscode, .cache). Skip them — they don't contain
            // user repos in practice.
            if name.hasPrefix(".") && name != "." && name != ".." { continue }

            let entryIsDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard entryIsDir else { continue }

            findRepositories(under: entry, into: &found)
        }
    }

    // MARK: - Per-repo inspection

    private enum InspectionOutcome: Sendable {
        case success(RepoInfo)
        case failure(ScanFailure)
    }

    private func inspect(at url: URL) async -> InspectionOutcome {
        async let measurements = SizeAndActivity.measure(at: url)
        let metadata: GitMetadata
        do {
            metadata = try await inspector.inspect(repoAt: url)
        } catch {
            return .failure(ScanFailure(path: url, reason: String(describing: error)))
        }
        let (size, mtime) = await measurements
        return .success(RepoInfo(
            path: url,
            sizeBytes: size,
            lastFileMTime: mtime,
            git: metadata
        ))
    }
}

/// File-system measurements computed in a detached task to keep the
/// recursive enumeration off the cooperative pool.
private enum SizeAndActivity {
    static func measure(at url: URL) async -> (sizeBytes: Int64, lastMTime: Date) {
        await Task.detached(priority: .utility) {
            measureSync(at: url)
        }.value
    }

    private static func measureSync(at url: URL) -> (Int64, Date) {
        var totalSize: Int64 = 0
        var maxMTime = Date.distantPast

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [
                .fileSizeKey,
                .contentModificationDateKey,
                .isRegularFileKey,
            ],
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return (0, .distantPast)
        }

        for case let fileURL as URL in enumerator {
            let attrs = try? fileURL.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey, .isRegularFileKey,
            ])
            guard attrs?.isRegularFile == true else { continue }

            let size = Int64(attrs?.fileSize ?? 0)
            totalSize += size

            // Exclude .git internals from mtime: pack/gc/refs churn
            // unrelated to user activity would otherwise mask true dormancy.
            if !fileURL.pathComponents.contains(".git"),
               let mtime = attrs?.contentModificationDate,
               mtime > maxMTime {
                maxMTime = mtime
            }
        }
        return (totalSize, maxMTime)
    }
}
