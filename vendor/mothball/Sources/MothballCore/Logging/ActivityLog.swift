import Foundation

/// Append-only plain-text record of archive operations. The format is
/// optimised for human inspection (`tail -f activity.log`) rather than
/// machine parsing — Mothball doesn't read the log back.
///
/// Writes are serialised through an actor so concurrent `append` calls
/// can't interleave bytes inside a single line, and silently swallow
/// errors so logging can never crash the archive flow.
public actor ActivityLog {
    public enum Event: Sendable {
        case archiveStart(path: URL, sizeBytes: Int64)
        case archiveSuccess(archive: URL, sourceBytes: Int64, archiveBytes: Int64)
        case archiveFailed(path: URL, error: String)
        case trashed(path: URL)
        case trashFailed(path: URL, error: String)
    }

    private let url: URL
    private let formatter: ISO8601DateFormatter

    public init(url: URL) {
        self.url = url
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        self.formatter = f
    }

    /// Resolves to `~/Library/Application Support/Mothball/activity.log`,
    /// creating the directory if needed. Throws only if the support
    /// directory is unreachable — past that point write errors are
    /// swallowed inside `append`.
    public static func userDefault() throws -> ActivityLog {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appending(path: "Mothball", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ActivityLog(url: dir.appending(path: "activity.log"))
    }

    public func append(_ event: Event, at date: Date = Date()) {
        let line = format(event, at: date) + "\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: [.atomic])
            }
        } catch {
            // Logging must never throw out of the archive flow. We
            // can't even log the logging failure without recursion.
        }
    }

    private func format(_ event: Event, at date: Date) -> String {
        let ts = formatter.string(from: date)
        switch event {
        case .archiveStart(let path, let size):
            return "\(ts) ARCHIVE_START path=\(path.path) size=\(size)"
        case .archiveSuccess(let archive, let src, let arc):
            return "\(ts) ARCHIVE_OK archive=\(archive.path) source_size=\(src) archive_size=\(arc)"
        case .archiveFailed(let path, let err):
            return "\(ts) ARCHIVE_FAIL path=\(path.path) error=\"\(escape(err))\""
        case .trashed(let path):
            return "\(ts) TRASH_OK path=\(path.path)"
        case .trashFailed(let path, let err):
            return "\(ts) TRASH_FAIL path=\(path.path) error=\"\(escape(err))\""
        }
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
