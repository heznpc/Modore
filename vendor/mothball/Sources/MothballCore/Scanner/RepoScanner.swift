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
    public let totalScanBudget: Duration
    public let measurementTimeout: Duration
    public let maxMeasurementEntries: Int
    private let inspectionStarted: (@Sendable (URL) -> Void)?

    public init(
        inspector: GitInspector = GitInspector(),
        prunedDirectoryNames: Set<String> = defaultPrunedNames,
        maxConcurrentInspections: Int = 8,
        totalScanBudget: Duration = .seconds(30),
        measurementTimeout: Duration = .seconds(5),
        maxMeasurementEntries: Int = 100_000
    ) {
        self.inspector = inspector
        self.prunedDirectoryNames = prunedDirectoryNames
        self.maxConcurrentInspections = max(1, maxConcurrentInspections)
        self.totalScanBudget = max(.zero, totalScanBudget)
        self.measurementTimeout = max(.milliseconds(100), measurementTimeout)
        self.maxMeasurementEntries = max(1, maxMeasurementEntries)
        self.inspectionStarted = nil
    }

    /// Test seam for proving that task-group cancellation stops admitting new
    /// repositories. Production callers use the public initializer above.
    init(
        inspector: GitInspector,
        prunedDirectoryNames: Set<String> = defaultPrunedNames,
        maxConcurrentInspections: Int = 8,
        totalScanBudget: Duration = .seconds(30),
        measurementTimeout: Duration = .seconds(5),
        maxMeasurementEntries: Int = 100_000,
        inspectionStarted: @escaping @Sendable (URL) -> Void
    ) {
        self.inspector = inspector
        self.prunedDirectoryNames = prunedDirectoryNames
        self.maxConcurrentInspections = max(1, maxConcurrentInspections)
        self.totalScanBudget = max(.zero, totalScanBudget)
        self.measurementTimeout = max(.milliseconds(100), measurementTimeout)
        self.maxMeasurementEntries = max(1, maxMeasurementEntries)
        self.inspectionStarted = inspectionStarted
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
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: totalScanBudget)
        var discovered: [URL] = []
        for root in roots {
            guard !Task.isCancelled else {
                return ScanReport(repos: [], failures: [])
            }
            findRepositories(under: root, into: &discovered)
        }

        guard !Task.isCancelled else {
            return ScanReport(repos: [], failures: [])
        }
        return await inspectDiscovered(discovered, deadline: deadline, clock: clock)
    }

    /// Inspects paths that the caller has already established as repository
    /// roots. This is the product path used by Modore's scree lineage: it must
    /// not turn a vanished `.git` marker into a recursive walk of an external
    /// or unavailable volume before the scan budget has even started.
    public func inspectKnownRepositories(_ repositories: [URL]) async -> ScanReport {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: totalScanBudget)
        return await inspectDiscovered(repositories, deadline: deadline, clock: clock)
    }

    private func inspectDiscovered(
        _ discovered: [URL],
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async -> ScanReport {
        guard !Task.isCancelled, !discovered.isEmpty else {
            return ScanReport(repos: [], failures: [])
        }

        // Bounded-concurrency pattern: seed the group with `limit` tasks,
        // then for every completion add one more from the iterator. The
        // group's natural backpressure keeps at most `limit` tasks in
        // flight without needing a hand-rolled counter.
        return await withTaskGroup(of: InspectionOutcome.self) { group in
            var nextIndex = 0
            var activeInspections = 0

            let remainingBudget = max(.zero, clock.now.duration(to: deadline))
            group.addTask {
                do {
                    try await Task.sleep(for: remainingBudget)
                    return .budgetExpired
                } catch {
                    return .budgetTimerCancelled
                }
            }

            for _ in 0..<maxConcurrentInspections {
                guard !Task.isCancelled,
                      nextIndex < discovered.count else { break }
                let repoURL = discovered[nextIndex]
                nextIndex += 1
                guard group.addTaskUnlessCancelled(operation: {
                    await self.inspect(at: repoURL)
                }) else { break }
                activeInspections += 1
            }

            var results: [RepoInfo] = []
            var failures: [ScanFailure] = []
            var stoppedForBudget = false
            while activeInspections > 0, let value = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                switch value {
                case .success(let info):
                    activeInspections -= 1
                    results.append(info)
                case .failure(let failure):
                    activeInspections -= 1
                    failures.append(failure)
                case .cancelled(let path):
                    activeInspections -= 1
                    if stoppedForBudget {
                        failures.append(ScanFailure(
                            path: path,
                            reason: Self.scanBudgetFailureReason
                        ))
                    }
                case .budgetExpired:
                    stoppedForBudget = true
                    failures.append(contentsOf: discovered[nextIndex...].map {
                        ScanFailure(path: $0, reason: Self.scanBudgetFailureReason)
                    })
                    nextIndex = discovered.count
                    group.cancelAll()
                case .budgetTimerCancelled:
                    break
                }
                if !stoppedForBudget,
                          !Task.isCancelled,
                          nextIndex < discovered.count {
                    let repoURL = discovered[nextIndex]
                    nextIndex += 1
                    if group.addTaskUnlessCancelled(operation: {
                        await self.inspect(at: repoURL)
                    }) {
                        activeInspections += 1
                    }
                }
            }
            group.cancelAll()
            return ScanReport(repos: results, failures: failures)
        }
    }

    // MARK: - Discovery

    /// Recursive walk that prunes at git repo boundaries and at known
    /// noise directories. Recursive (not enumerator-based) so we can
    /// stop descending the moment we find a `.git` — avoids walking
    /// millions of files inside vendored dependencies.
    private func findRepositories(under root: URL, into found: inout [URL]) {
        guard !Task.isCancelled else { return }
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
            guard !Task.isCancelled else { return }
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
        case cancelled(URL)
        case budgetExpired
        case budgetTimerCancelled
    }

    private static let scanBudgetFailureReason =
        "전체 저장소 판정 시간 상한을 초과해 이 저장소를 확인하지 못했습니다."

    private func inspect(at url: URL) async -> InspectionOutcome {
        guard !Task.isCancelled else { return .cancelled(url) }
        inspectionStarted?(url)
        guard !Task.isCancelled else { return .cancelled(url) }
        async let measurements = SizeAndActivity.measure(
            at: url,
            maxEntries: maxMeasurementEntries,
            timeout: measurementTimeout
        )
        let metadata: GitMetadata
        do {
            metadata = try await inspector.inspect(repoAt: url)
        } catch is CancellationError {
            return .cancelled(url)
        } catch {
            return .failure(ScanFailure(path: url, reason: String(describing: error)))
        }
        guard !Task.isCancelled else { return .cancelled(url) }
        let size: Int64
        let mtime: Date
        do {
            (size, mtime) = try await measurements
        } catch is CancellationError {
            return .cancelled(url)
        } catch {
            return .failure(ScanFailure(path: url, reason: String(describing: error)))
        }
        guard !Task.isCancelled else { return .cancelled(url) }
        return .success(RepoInfo(
            path: url,
            sizeBytes: size,
            lastFileMTime: mtime,
            git: metadata
        ))
    }
}

/// File-system measurements run in a bounded private process group. A local
/// `FileManager` enumerator cannot interrupt a blocked metadata read on an
/// unavailable external volume; the subprocess boundary gives both timeout
/// and cancellation a hard process-tree stop instead of leaving a worker
/// behind after the Work screen has moved on.
enum SizeAndActivity {
    enum Error: Swift.Error, CustomStringConvertible {
        case entryLimitExceeded(Int)
        case commandFailed(String)
        case malformedOutput
        case process(ProcessError)

        var description: String {
            switch self {
            case .entryLimitExceeded(let limit):
                return "파일 수 측정 상한(\(limit)개)을 초과해 저장소 판정이 완전하지 않습니다."
            case .commandFailed(let detail):
                return "파일 시스템 측정을 완료하지 못했습니다: \(detail)"
            case .malformedOutput:
                return "파일 시스템 측정 결과를 확인할 수 없습니다."
            case .process(let processError):
                switch processError {
                case .timedOut:
                    return "파일 시스템 측정이 시간 상한을 초과해 저장소 판정이 완전하지 않습니다."
                case .spawnFailed:
                    return "파일 시스템 측정 프로세스를 시작하지 못했습니다."
                }
            }
        }
    }

    private static let activityScript = #"""
    set -o pipefail
    /usr/bin/find -x "$2" -path '*/.git' -prune -o -type f \
      -exec /usr/bin/stat -f '%m' {} + |
    /usr/bin/awk -v limit="$1" '
      {
        count += 1
        if ($1 > latest) latest = $1
        if (count > limit) exit 75
      }
      END {
        if (count <= limit) printf "%.0f %.0f\n", count, latest
      }
    '
    """#

    static func measure(
        at url: URL,
        maxEntries: Int = 100_000,
        timeout: Duration = .seconds(5),
        shellExecutable: URL = URL(fileURLWithPath: "/bin/bash")
    ) async throws -> (sizeBytes: Int64, lastMTime: Date) {
        let boundedEntries = max(1, maxEntries)
        do {
            async let usage = ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/du"),
                arguments: ["-skx", "--", url.path],
                workingDirectory: safeWorkingDirectory,
                timeout: timeout
            )
            async let activity = ProcessRunner.run(
                executable: shellExecutable,
                arguments: [
                    "-p", "-c", activityScript, "modore-measure",
                    String(boundedEntries), url.path,
                ],
                workingDirectory: safeWorkingDirectory,
                timeout: timeout
            )
            let (usageResult, activityResult) = try await (usage, activity)

            guard usageResult.isSuccess else {
                throw Error.commandFailed(usageResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            guard activityResult.exitCode != 75 else {
                throw Error.entryLimitExceeded(boundedEntries)
            }
            guard activityResult.isSuccess else {
                throw Error.commandFailed(activityResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            guard let kilobytesText = usageResult.stdout.split(whereSeparator: \ .isWhitespace).first,
                  let kilobytes = Int64(kilobytesText),
                  kilobytes >= 0,
                  kilobytes <= Int64.max / 1_024 else {
                throw Error.malformedOutput
            }
            let activityFields = activityResult.stdout.split(whereSeparator: \ .isWhitespace)
            guard activityFields.count == 2,
                  Int(activityFields[0]) != nil,
                  let latestSeconds = TimeInterval(activityFields[1]) else {
                throw Error.malformedOutput
            }
            let latest = latestSeconds > 0
                ? Date(timeIntervalSince1970: latestSeconds)
                : Date.distantPast
            return (kilobytes * 1_024, latest)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as Error {
            throw error
        } catch let error as ProcessError {
            throw Error.process(error)
        }
    }

    private static let safeWorkingDirectory = URL(
        fileURLWithPath: "/private/tmp",
        isDirectory: true
    )
}
