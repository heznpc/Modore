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

enum StorageWatchSnapshotStore {
    static let maximumBytes = 1 * 1_024 * 1_024
    static let maximumRows = 24 * 8

    static var snapshotURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/PC Health Check/storage-watch-paths.tsv"
            )
    }

    static func load(from url: URL = snapshotURL) -> [StorageWatchPathSnapshot] {
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
            return []
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
