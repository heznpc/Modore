import Foundation

/// Naming contract for the archive and its sidecar manifest.
struct ArchiveArtifactPair: Sendable, Equatable {
    static let archiveExtension = "tar.zst"
    static let manifestExtension = "json"

    let archive: URL
    let manifest: URL

    init(baseName: String, directory: URL) {
        self.archive = directory.appending(path: "\(baseName).\(Self.archiveExtension)")
        self.manifest = directory.appending(path: "\(baseName).\(Self.manifestExtension)")
    }

    init(manifestURL: URL) {
        let directory = manifestURL.deletingLastPathComponent()
        let baseName = manifestURL.deletingPathExtension().lastPathComponent
        self.init(baseName: baseName, directory: directory)
    }
}

/// All path planning collected in one place so it is easy to inspect
/// and unit-test independently of the orchestrator.
struct ArchivePlan {
    let repoPath: URL
    let archiveTmp: URL
    let archiveFinal: URL
    let manifestTmp: URL
    let manifestFinal: URL

    init(repo: RepoInfo, archiveDirectory: URL, now: Date = Date()) {
        self.repoPath = repo.path
        let stamp = ArchivePlan.timestamp(now)
        let artifacts = ArchiveArtifactPair(
            baseName: "\(repo.path.lastPathComponent)_\(stamp)",
            directory: archiveDirectory
        )
        self.archiveFinal = artifacts.archive
        self.manifestFinal = artifacts.manifest
        self.archiveTmp = URL(fileURLWithPath: artifacts.archive.path + ".tmp")
        self.manifestTmp = URL(fileURLWithPath: artifacts.manifest.path + ".tmp")
    }

    private static func timestamp(_ date: Date) -> String {
        // Filesystem-safe: no colons, no spaces. Sortable.
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withYear, .withMonth, .withDay, .withDashSeparatorInDate,
                           .withTime, .withColonSeparatorInTime]
        let raw = f.string(from: date)
        return raw.replacingOccurrences(of: ":", with: "-")
    }
}
