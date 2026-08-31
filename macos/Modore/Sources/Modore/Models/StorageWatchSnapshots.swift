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
}

struct StorageWatchPathEvent: Identifiable, Equatable, Sendable {
    let capturedAt: Date
    let rows: [StorageWatchPathSnapshot]

    var id: Date { capturedAt }
}

enum StorageWatchSignalKind: String, Sendable {
    case swap
    case processRSS = "process_rss"
}

struct StorageWatchSignalSnapshot: Identifiable, Equatable, Sendable {
    let capturedAt: Date
    let kind: StorageWatchSignalKind
    let valueKB: Double
    let allocatedKB: Double
    let pid: Int
    let label: String
    let reference: String

    var id: String {
        "\(capturedAt.timeIntervalSince1970)|\(kind.rawValue)|\(pid)|\(reference)"
    }
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
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            if fields.count == 2, fields[0] == "lastEvidenceAt" {
                guard committedAt == nil,
                      let parsed = try? isoFormat.parse(String(fields[1])) else {
                    return nil
                }
                committedAt = parsed
            }
        }
        return committedAt
    }

    private static let isoFormat = Date.ISO8601FormatStyle()
}

enum StorageWatchSnapshotStore {
    static let maximumBytes = 1 * 1_024 * 1_024
    static let maximumRows = 24 * 8

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
              fields[5] == "ok" else {
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
            readCommittedAt: {
                StorageWatchEvidenceCommitStore.load(from: stateURL)
            },
            readPaths: {
                StorageWatchSnapshotStore.loadIfAvailable(from: pathURL)
            },
            readSignals: {
                StorageWatchSignalStore.loadIfAvailable(from: signalURL)
            }
        )
    }

    /// The watcher replaces paths and signals before advancing the pointer in
    /// its state file. Reading that pointer on both sides detects a completed
    /// commit, while selecting only its exact event prevents a newer in-flight
    /// tail from becoming visible before the pointer advances.
    static func loadStable(
        maximumAttempts: Int = maximumReadAttempts,
        readCommittedAt: () -> Date?,
        readPaths: () -> [StorageWatchPathSnapshot]?,
        readSignals: () -> [StorageWatchSignalSnapshot]?
    ) -> StorageWatchEvidenceSnapshot? {
        let attemptCount = min(max(0, maximumAttempts), maximumReadAttempts)
        for _ in 0..<attemptCount {
            guard let pointerBefore = readCommittedAt(),
                  let paths = readPaths(),
                  let signals = readSignals(),
                  let pointerAfter = readCommittedAt(),
                  pointerBefore == pointerAfter else {
                continue
            }

            let pathEvents = StorageWatchSnapshotStore.events(from: paths)
                .filter { $0.capturedAt == pointerBefore }
            // Every successful watcher evidence commit contains path rows,
            // including explicit timed_out/unavailable rows. Requiring that
            // anchor also rejects a pointer whose referenced event was not in
            // the bounded read or whose file was only partially replaced.
            guard !pathEvents.isEmpty else { continue }
            let signalEvents = StorageWatchSignalStore.events(from: signals)
                .filter { $0.capturedAt == pointerBefore }
            return StorageWatchEvidenceSnapshot(
                pathEvents: pathEvents,
                signalEvents: signalEvents,
                committedAt: pointerBefore
            )
        }
        return nil
    }
}
