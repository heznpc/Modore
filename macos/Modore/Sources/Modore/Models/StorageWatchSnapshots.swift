import Darwin
import Foundation

struct StorageWatchPathSnapshot: Identifiable, Equatable, Sendable {
    let capturedAt: Date
    let sizeGB: Double
    let status: String
    let label: String
    let path: String

    var id: String {
        "\(capturedAt.timeIntervalSince1970)|\(path)"
    }

    var measured: Bool { status == "ok" }

    var measurementText: String {
        if measured {
            return String(format: "%.1fGB", sizeGB)
        }
        if sizeGB > 0 {
            return sizeGB >= 0.1
                ? String(format: "최소 %.1fGB", sizeGB)
                : String(format: "최소 %.1fMB", sizeGB * 1_024)
        }
        return status == "timed_out" ? "시간 제한" : "측정 실패"
    }
}

struct StorageWatchPathEvent: Identifiable, Equatable, Sendable {
    let capturedAt: Date
    let rows: [StorageWatchPathSnapshot]

    var id: Date { capturedAt }
}

struct StorageWatchPathChange: Identifiable, Equatable, Sendable {
    let label: String
    let path: String
    let beforeGB: Double
    let afterGB: Double

    var id: String { path }
    var deltaGB: Double { afterGB - beforeGB }
}

struct StorageWatchPathChangeSummary: Equatable, Sendable {
    static let minimumMeaningfulDeltaGB = 0.05

    let previousAt: Date
    let currentAt: Date
    let changes: [StorageWatchPathChange]

    var growing: [StorageWatchPathChange] {
        changes.filter { $0.deltaGB > 0 }.sorted { $0.deltaGB > $1.deltaGB }
    }

    var shrinking: [StorageWatchPathChange] {
        changes.filter { $0.deltaGB < 0 }.sorted { $0.deltaGB < $1.deltaGB }
    }

    static func latest(
        pathEvents: [StorageWatchPathEvent],
        committedAt: Date
    ) -> StorageWatchPathChangeSummary? {
        let sorted = pathEvents
            .filter { $0.capturedAt <= committedAt }
            .sorted { $0.capturedAt < $1.capturedAt }
        // `committedAt` is the latest overall evidence commit. A signal-only
        // commit can be newer than the last path capture, so use the newest
        // bounded path pair at or before it rather than requiring equality.
        guard let current = sorted.last,
              let previous = sorted.dropLast().last else {
            return nil
        }

        let before = measuredRows(in: previous)
        let after = measuredRows(in: current)
        let sharedPaths = Set(before.keys).intersection(after.keys)
        let changes = sharedPaths.compactMap { path -> StorageWatchPathChange? in
            guard let old = before[path], let new = after[path] else { return nil }
            return StorageWatchPathChange(
                label: new.label,
                path: path,
                beforeGB: old.sizeGB,
                afterGB: new.sizeGB
            )
        }.filter { abs($0.deltaGB) >= minimumMeaningfulDeltaGB }
            .sorted {
                if abs($0.deltaGB) != abs($1.deltaGB) {
                    return abs($0.deltaGB) > abs($1.deltaGB)
                }
                return $0.path < $1.path
            }

        return StorageWatchPathChangeSummary(
            previousAt: previous.capturedAt,
            currentAt: current.capturedAt,
            changes: changes
        )
    }

    private static func measuredRows(
        in event: StorageWatchPathEvent
    ) -> [String: StorageWatchPathSnapshot] {
        event.rows.reduce(into: [:]) { result, row in
            guard row.measured else { return }
            let normalized = StorageHistoryEntry.normalizedPath(row.path)
            result[normalized] = row
        }
    }
}

enum StorageWatchSignalKind: String, Sendable {
    case swap
    case processRSS = "process_rss"
}

enum StorageWatchSignalStatus: String, Sendable {
    case ok
    case timedOut = "timed_out"
    case outputLimited = "output_limited"
    case failed
}

struct StorageWatchSignalSnapshot: Identifiable, Equatable, Sendable {
    let capturedAt: Date
    let kind: StorageWatchSignalKind
    let valueKB: Double
    let allocatedKB: Double
    let pid: Int
    let status: StorageWatchSignalStatus
    let label: String
    let reference: String

    var id: String {
        "\(capturedAt.timeIntervalSince1970)|\(kind.rawValue)|\(pid)|\(reference)"
    }

    /// A non-`ok` row still contains evidence captured before the bounded
    /// command stopped, but it must never be presented as a complete sample.
    var isComplete: Bool { status == .ok }
    var isPartial: Bool { !isComplete }
}

struct StorageWatchSignalEvent: Identifiable, Equatable, Sendable {
    let capturedAt: Date
    let rows: [StorageWatchSignalSnapshot]

    var id: Date { capturedAt }
}

struct StorageWatchEvidenceEvent: Equatable, Sendable {
    let capturedAt: Date
    let pathEvent: StorageWatchPathEvent?
    let signalEvent: StorageWatchSignalEvent?

    static func latest(
        pathEvents: [StorageWatchPathEvent],
        signalEvents: [StorageWatchSignalEvent],
        committedAt: Date
    ) -> StorageWatchEvidenceEvent? {
        let pathEvent = pathEvents.last { $0.capturedAt == committedAt }
        let signalEvent = signalEvents.last { $0.capturedAt == committedAt }
        guard pathEvent != nil || signalEvent != nil else { return nil }
        return StorageWatchEvidenceEvent(
            capturedAt: committedAt,
            pathEvent: pathEvent,
            signalEvent: signalEvent
        )
    }
}

struct StorageWatchEvidenceSnapshot: Equatable, Sendable {
    let pathEvents: [StorageWatchPathEvent]
    let signalEvents: [StorageWatchSignalEvent]
    let committedAt: Date
    let pathCommittedAt: Date?

    init(
        pathEvents: [StorageWatchPathEvent],
        signalEvents: [StorageWatchSignalEvent],
        committedAt: Date
    ) {
        self.pathEvents = pathEvents
        self.signalEvents = signalEvents
        self.committedAt = committedAt
        self.pathCommittedAt = committedAt
    }

    init(
        pathEvents: [StorageWatchPathEvent],
        signalEvents: [StorageWatchSignalEvent],
        committedAt: Date,
        pathCommittedAt: Date?
    ) {
        self.pathEvents = pathEvents
        self.signalEvents = signalEvents
        self.committedAt = committedAt
        self.pathCommittedAt = pathCommittedAt
    }
}

struct StorageWatchEvidenceCommit: Equatable, Sendable {
    let previousAt: Date?
    let committedAt: Date
    let previousPathAt: Date?
    let pathCommittedAt: Date?

    init(
        previousAt: Date?,
        committedAt: Date
    ) {
        self.previousAt = previousAt
        self.committedAt = committedAt
        self.previousPathAt = previousAt
        self.pathCommittedAt = committedAt
    }

    init(
        previousAt: Date?,
        committedAt: Date,
        previousPathAt: Date?,
        pathCommittedAt: Date?
    ) {
        self.previousAt = previousAt
        self.committedAt = committedAt
        self.previousPathAt = previousPathAt
        self.pathCommittedAt = pathCommittedAt
    }
}

enum StorageWatchEvidenceCommitStore {
    static let maximumBytes = 64 * 1_024

    static var stateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(RuntimeWorkspace.applicationSupportName)
            .appendingPathComponent("storage-watch.tsv")
    }

    static func load(from url: URL = stateURL) -> Date? {
        loadCommit(from: url)?.committedAt
    }

    static func loadCommit(from url: URL = stateURL) -> StorageWatchEvidenceCommit? {
        guard let parentIdentity = FilesystemIdentity.directory(
            at: url.deletingLastPathComponent()
        ),
              let data = try? SecureLocalFileIO.boundedRead(
                from: url,
                maximumBytes: maximumBytes,
                requireCurrentOwner: true,
                expectedParentIdentity: parentIdentity
              ),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        var committedAt: Date?
        var previousAt: Date?
        var pathCommittedAt: Date?
        var previousPathAt: Date?
        var sawPathCommittedAt = false
        var sawPreviousPathAt = false
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2 else { continue }
            switch fields[0] {
            case "lastEvidenceAt":
                guard committedAt == nil,
                      let parsed = try? isoFormat.parse(String(fields[1])) else { return nil }
                committedAt = parsed
            case "previousEvidenceAt":
                guard previousAt == nil else { return nil }
                if !fields[1].isEmpty {
                    guard let parsed = try? isoFormat.parse(String(fields[1])) else { return nil }
                    previousAt = parsed
                }
            case "lastPathEvidenceAt":
                guard !sawPathCommittedAt else { return nil }
                sawPathCommittedAt = true
                if !fields[1].isEmpty {
                    guard let parsed = try? isoFormat.parse(String(fields[1])) else { return nil }
                    pathCommittedAt = parsed
                }
            case "previousPathEvidenceAt":
                guard !sawPreviousPathAt else { return nil }
                sawPreviousPathAt = true
                if !fields[1].isEmpty {
                    guard let parsed = try? isoFormat.parse(String(fields[1])) else { return nil }
                    previousPathAt = parsed
                }
            default:
                continue
            }
        }
        guard let committedAt,
              previousAt == nil || previousAt! < committedAt else { return nil }
        let resolvedPathCommittedAt: Date?
        let resolvedPreviousPathAt: Date?
        if !sawPathCommittedAt, !sawPreviousPathAt {
            // v1 stored only the overall evidence pair, which was also the
            // path pair. Preserve that legacy meaning.
            resolvedPathCommittedAt = committedAt
            resolvedPreviousPathAt = previousAt
        } else {
            // v2 always writes both keys. Two empty values mean that a valid
            // signal-only commit exists before the first path capture.
            guard sawPathCommittedAt, sawPreviousPathAt else { return nil }
            guard pathCommittedAt != nil || previousPathAt == nil else { return nil }
            resolvedPathCommittedAt = pathCommittedAt
            resolvedPreviousPathAt = previousPathAt
        }
        guard resolvedPathCommittedAt == nil
                || resolvedPathCommittedAt! <= committedAt,
              resolvedPathCommittedAt != nil
                || resolvedPreviousPathAt == nil,
              resolvedPreviousPathAt == nil
                || resolvedPreviousPathAt! < resolvedPathCommittedAt! else { return nil }
        return StorageWatchEvidenceCommit(
            previousAt: previousAt,
            committedAt: committedAt,
            previousPathAt: resolvedPreviousPathAt,
            pathCommittedAt: resolvedPathCommittedAt
        )
    }

    private static let isoFormat = Date.ISO8601FormatStyle()
}

enum StorageWatchSnapshotStore {
    static let maximumBytes = 1 * 1_024 * 1_024
    // The watcher retains up to twelve path rows per event: four transient
    // workspaces, four Simulator runtimes, dyld, Devices, and two general roots.
    static let maximumRows = 24 * 12

    static var snapshotURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(RuntimeWorkspace.applicationSupportName)
            .appendingPathComponent("storage-watch-paths.tsv")
    }

    static func load(from url: URL = snapshotURL) -> [StorageWatchPathSnapshot] {
        loadIfAvailable(from: url) ?? []
    }

    static func loadIfAvailable(
        from url: URL = snapshotURL
    ) -> [StorageWatchPathSnapshot]? {
        guard let parentIdentity = FilesystemIdentity.directory(
            at: url.deletingLastPathComponent()
        ),
              let data = try? SecureLocalFileIO.boundedRead(
                from: url,
                maximumBytes: maximumBytes,
                requireCurrentOwner: true,
                expectedParentIdentity: parentIdentity
              ),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        return text
            .split(whereSeparator: \.isNewline)
            .suffix(maximumRows)
            .compactMap(parse)
            .sorted {
                if $0.capturedAt != $1.capturedAt {
                    return $0.capturedAt < $1.capturedAt
                }
                if $0.sizeGB != $1.sizeGB {
                    return $0.sizeGB > $1.sizeGB
                }
                return $0.path < $1.path
            }
    }

    static func events(
        from snapshots: [StorageWatchPathSnapshot]
    ) -> [StorageWatchPathEvent] {
        Dictionary(grouping: snapshots, by: \.capturedAt)
            .map { capturedAt, rows in
                StorageWatchPathEvent(
                    capturedAt: capturedAt,
                    rows: rows.sorted {
                        if $0.measured != $1.measured { return $0.measured }
                        if $0.sizeGB != $1.sizeGB { return $0.sizeGB > $1.sizeGB }
                        return $0.path < $1.path
                    }
                )
            }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    private static func parse(_ line: Substring) -> StorageWatchPathSnapshot? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 5,
              let capturedAt = try? isoFormat.parse(String(fields[0])),
              let sizeKB = Double(fields[1]),
              sizeKB.isFinite,
              sizeKB >= 0 else {
            return nil
        }

        let status = String(fields[2])
        let label = String(fields[3])
        let path = String(fields[4])
        guard allowedStatuses.contains(status),
              !label.isEmpty,
              label.utf8.count <= 256,
              path.hasPrefix("/"),
              path.utf8.count <= 16_384,
              !label.utf8.contains(0),
              !path.utf8.contains(0) else {
            return nil
        }

        return StorageWatchPathSnapshot(
            capturedAt: capturedAt,
            sizeGB: sizeKB / 1_048_576,
            status: status,
            label: label,
            path: path
        )
    }

    private static let allowedStatuses: Set<String> = [
        "ok", "timed_out", "unavailable",
    ]
    private static let isoFormat = Date.ISO8601FormatStyle()
}

enum StorageWatchSignalStore {
    static let maximumBytes = 1 * 1_024 * 1_024
    static let maximumRows = 24 * 4

    static var signalURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(RuntimeWorkspace.applicationSupportName)
            .appendingPathComponent("storage-watch-signals.tsv")
    }

    static func load(from url: URL = signalURL) -> [StorageWatchSignalSnapshot] {
        loadIfAvailable(from: url) ?? []
    }

    static func loadIfAvailable(
        from url: URL = signalURL
    ) -> [StorageWatchSignalSnapshot]? {
        guard let parentIdentity = FilesystemIdentity.directory(
            at: url.deletingLastPathComponent()
        ),
              let data = try? SecureLocalFileIO.boundedRead(
                from: url,
                maximumBytes: maximumBytes,
                requireCurrentOwner: true,
                expectedParentIdentity: parentIdentity
              ),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        return text
            .split(whereSeparator: \.isNewline)
            .suffix(maximumRows)
            .compactMap(parse)
            .sorted {
                if $0.capturedAt != $1.capturedAt {
                    return $0.capturedAt < $1.capturedAt
                }
                if $0.kind != $1.kind { return $0.kind == .swap }
                if $0.valueKB != $1.valueKB { return $0.valueKB > $1.valueKB }
                return $0.reference < $1.reference
            }
    }

    static func events(
        from snapshots: [StorageWatchSignalSnapshot]
    ) -> [StorageWatchSignalEvent] {
        Dictionary(grouping: snapshots, by: \.capturedAt)
            .map { capturedAt, rows in
                StorageWatchSignalEvent(
                    capturedAt: capturedAt,
                    rows: rows.sorted {
                        if $0.kind != $1.kind { return $0.kind == .swap }
                        if $0.valueKB != $1.valueKB { return $0.valueKB > $1.valueKB }
                        return $0.reference < $1.reference
                    }
                )
            }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    private static func parse(_ line: Substring) -> StorageWatchSignalSnapshot? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 8,
              let capturedAt = try? isoFormat.parse(String(fields[0])),
              let kind = StorageWatchSignalKind(rawValue: String(fields[1])),
              let valueKB = Double(fields[2]), valueKB.isFinite, valueKB >= 0,
              let allocatedKB = Double(fields[3]),
              allocatedKB.isFinite, allocatedKB >= 0,
              let pid = Int(fields[4]), pid >= 0,
              let status = StorageWatchSignalStatus(rawValue: String(fields[5])) else {
            return nil
        }

        let label = String(fields[6])
        let reference = String(fields[7])
        guard !label.isEmpty,
              label.utf8.count <= 256,
              !label.utf8.contains(0),
              !reference.utf8.contains(0) else {
            return nil
        }
        switch kind {
        case .swap:
            guard pid == 0,
                  allocatedKB >= valueKB,
                  reference.hasPrefix("/"),
                  reference.utf8.count <= 4_096 else { return nil }
        case .processRSS:
            guard pid > 0,
                  allocatedKB == 0,
                  reference == label,
                  reference.utf8.count <= 256 else { return nil }
        }

        return StorageWatchSignalSnapshot(
            capturedAt: capturedAt,
            kind: kind,
            valueKB: valueKB,
            allocatedKB: allocatedKB,
            pid: pid,
            status: status,
            label: label,
            reference: reference
        )
    }

    private static let isoFormat = Date.ISO8601FormatStyle()
}

enum StorageWatchEvidenceStore {
    static let maximumReadAttempts = 3

    static func load(
        stateURL: URL = StorageWatchEvidenceCommitStore.stateURL,
        pathURL: URL = StorageWatchSnapshotStore.snapshotURL,
        signalURL: URL = StorageWatchSignalStore.signalURL
    ) -> StorageWatchEvidenceSnapshot? {
        loadStable(
            readCommit: {
                StorageWatchEvidenceCommitStore.loadCommit(from: stateURL)
            },
            readPaths: {
                loadOptionalFile(at: pathURL) {
                    StorageWatchSnapshotStore.loadIfAvailable(from: pathURL)
                }
            },
            readSignals: {
                loadOptionalFile(at: signalURL) {
                    StorageWatchSignalStore.loadIfAvailable(from: signalURL)
                }
            }
        )
    }

    /// The watcher replaces paths and signals before advancing the pointer in
    /// its state file. Reading that pointer on both sides detects a completed
    /// commit, while selecting only its exact event prevents a newer in-flight
    /// tail from becoming visible before the pointer advances.
    static func loadStable(
        maximumAttempts: Int = maximumReadAttempts,
        readCommit: () -> StorageWatchEvidenceCommit?,
        readPaths: () -> [StorageWatchPathSnapshot]?,
        readSignals: () -> [StorageWatchSignalSnapshot]?
    ) -> StorageWatchEvidenceSnapshot? {
        let attemptCount = min(max(0, maximumAttempts), maximumReadAttempts)
        for _ in 0..<attemptCount {
            guard let commitBefore = readCommit(),
                  let paths = readPaths(),
                  let signals = readSignals(),
                  let commitAfter = readCommit(),
                  commitBefore == commitAfter else {
                continue
            }

            let signalTimes = Set(
                [commitBefore.previousAt, commitBefore.committedAt].compactMap { $0 }
            )
            let pathTimes = Set(
                [commitBefore.previousPathAt, commitBefore.pathCommittedAt].compactMap { $0 }
            )
            let pathEvents = StorageWatchSnapshotStore.events(from: paths)
                .filter { pathTimes.contains($0.capturedAt) }
            let signalEvents = StorageWatchSignalStore.events(from: signals)
                .filter { signalTimes.contains($0.capturedAt) }
            // Legacy watchers could commit path-only or signal-only evidence.
            // Require the current pointer to exist in at least one bounded
            // history; this still rejects a torn write without discarding the
            // valid half merely because the other evidence file never existed.
            guard pathEvents.contains(where: {
                $0.capturedAt == commitBefore.committedAt
            }) || signalEvents.contains(where: {
                $0.capturedAt == commitBefore.committedAt
            }) else { continue }
            return StorageWatchEvidenceSnapshot(
                pathEvents: pathEvents,
                signalEvents: signalEvents,
                committedAt: commitBefore.committedAt,
                pathCommittedAt: commitBefore.pathCommittedAt
            )
        }
        return nil
    }

    /// Compatibility seam for callers and fixtures produced before the watcher
    /// began committing an explicit previous-evidence pointer. Such evidence is
    /// still safe to show, but cannot support a path delta until the next pair.
    static func loadStable(
        maximumAttempts: Int = maximumReadAttempts,
        readCommittedAt: () -> Date?,
        readPaths: () -> [StorageWatchPathSnapshot]?,
        readSignals: () -> [StorageWatchSignalSnapshot]?
    ) -> StorageWatchEvidenceSnapshot? {
        loadStable(
            maximumAttempts: maximumAttempts,
            readCommit: {
                readCommittedAt().map {
                    StorageWatchEvidenceCommit(previousAt: nil, committedAt: $0)
                }
            },
            readPaths: readPaths,
            readSignals: readSignals
        )
    }

    private static func loadOptionalFile<Value>(
        at url: URL,
        read: () -> Value?
    ) -> Value? where Value: RangeReplaceableCollection {
        if !pathEntryExists(url) { return Value() }
        return read()
    }

    private static func pathEntryExists(_ url: URL) -> Bool {
        var metadata = stat()
        return url.path.withCString { Darwin.lstat($0, &metadata) == 0 }
    }
}
