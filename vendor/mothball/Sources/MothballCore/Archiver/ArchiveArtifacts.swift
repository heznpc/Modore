import Foundation

/// Naming contract for the archive, its sidecar manifest, and the
/// optional session archive beside them.
///
/// Sessions get their own `.tar.zst` rather than a second top-level
/// directory inside the workspace archive, for three reasons. `Restorer`
/// requires the workspace archive to contain exactly one top-level
/// directory, and that invariant is what stops a tampered tarball from
/// scattering surprises into the user's filesystem. Every v1 archive
/// already on disk has that shape, so keeping it means restore stays
/// version-independent. And the two halves are wanted separately in
/// practice: reading back a conversation is a different act from
/// recreating the working tree it ran in, and the session archive is
/// usually the smaller download of the two.
struct ArchiveArtifactPair: Sendable, Equatable {
    static let archiveExtension = "tar.zst"
    static let manifestExtension = "json"
    static let sessionsExtension = "sessions.tar.zst"

    let archive: URL
    let manifest: URL
    let sessions: URL

    init(baseName: String, directory: URL) {
        self.archive = directory.appending(path: "\(baseName).\(Self.archiveExtension)")
        self.manifest = directory.appending(path: "\(baseName).\(Self.manifestExtension)")
        self.sessions = directory.appending(path: "\(baseName).\(Self.sessionsExtension)")
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
    let sessionsTmp: URL
    let sessionsFinal: URL

    init(repo: RepoInfo, archiveDirectory: URL, now: Date = Date()) {
        self.repoPath = repo.path
        let stamp = ArchivePlan.timestamp(now)
        let artifacts = ArchiveArtifactPair(
            baseName: "\(repo.path.lastPathComponent)_\(stamp)",
            directory: archiveDirectory
        )
        self.archiveFinal = artifacts.archive
        self.manifestFinal = artifacts.manifest
        self.sessionsFinal = artifacts.sessions
        self.archiveTmp = URL(fileURLWithPath: artifacts.archive.path + ".tmp")
        self.manifestTmp = URL(fileURLWithPath: artifacts.manifest.path + ".tmp")
        self.sessionsTmp = URL(fileURLWithPath: artifacts.sessions.path + ".tmp")
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
