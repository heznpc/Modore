import Foundation

/// Sidecar JSON that lives next to every `.tar.zst` archive.
///
/// The archive itself is opaque (just a compressed tar), so this manifest
/// is the only place a future user can answer "what was this and how do
/// I get it back?". Treat the schema as a stable contract — bump
/// `schemaVersion` on any breaking change.
public struct ArchiveManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let archivedAt: Date
    public let archivedBy: String
    public let originalPath: String
    public let sizeBytesBefore: Int64
    public let sizeBytesArchive: Int64
    public let git: Git
    public let restoreHint: String?

    /// Every absolute path this workspace is known to have occupied,
    /// most recent last. `originalPath` stays as the single value a v1
    /// reader understands; this is the list a session binding can
    /// actually be matched against, because a transcript records where
    /// the work happened at the time, not where it ended up.
    ///
    /// Schema 2. A v1 manifest decodes with just `originalPath` here.
    public let historicalPaths: [String]

    /// What was known about this workspace's agent sessions when it was
    /// archived, and where their bytes went. `nil` only in a v1 manifest,
    /// where the question was never asked — which is exactly the state
    /// `ContinuityAssessment.notAssessed` exists to keep distinguishable
    /// from "asked, found nothing".
    ///
    /// Schema 2.
    public let continuity: Continuity?

    public struct Git: Codable, Sendable, Equatable {
        public let origin: String?
        public let branch: String?
        public let headSHA: String?
        public let lastCommitDate: Date?
        public let aheadOfOrigin: Int?
        public let wasDirty: Bool

        public init(
            origin: String?,
            branch: String?,
            headSHA: String?,
            lastCommitDate: Date?,
            aheadOfOrigin: Int?,
            wasDirty: Bool
        ) {
            self.origin = origin
            self.branch = branch
            self.headSHA = headSHA
            self.lastCommitDate = lastCommitDate
            self.aheadOfOrigin = aheadOfOrigin
            self.wasDirty = wasDirty
        }

        public init(from metadata: GitMetadata) {
            self.init(
                origin: metadata.originURL,
                branch: metadata.currentBranch,
                headSHA: metadata.headSHA,
                lastCommitDate: metadata.lastCommitDate,
                aheadOfOrigin: metadata.aheadOfOrigin,
                wasDirty: metadata.isDirty
            )
        }
    }

    /// Session-preservation record. Written for every schema-2 archive,
    /// including the ones with nothing to preserve — an archive whose
    /// `assessment` is `assessed-no-sessions` is making a positive claim
    /// that a binder ran, which a missing block cannot make.
    public struct Continuity: Codable, Sendable, Equatable {
        /// `ContinuityAssessment.manifestTag`.
        public let assessment: String

        /// Filename of the sibling session archive, or `nil` when there
        /// were no sessions to seal. A *name*, not a path: the archive
        /// folder gets moved and renamed, and the pair is found by
        /// colocation the same way the `.tar.zst` already is.
        public let sessionArchive: String?

        public let sessions: [SealedSession]

        /// Legacy, read-only. Standalone Mothball wrote an override here
        /// while it had no session binder; nothing writes one now. Kept
        /// so those manifests still decode -- `assessment` is a plain
        /// string, so a tag this build no longer produces costs nothing
        /// to read back.
        public let overrideReason: String?

        public init(
            assessment: String,
            sessionArchive: String?,
            sessions: [SealedSession],
            overrideReason: String?
        ) {
            self.assessment = assessment
            self.sessionArchive = sessionArchive
            self.sessions = sessions
            self.overrideReason = overrideReason
        }

        public var totalSessionBytes: Int64 { sessions.reduce(0) { $0 + $1.sizeBytes } }
    }

    public init(
        schemaVersion: Int,
        archivedAt: Date,
        archivedBy: String,
        originalPath: String,
        sizeBytesBefore: Int64,
        sizeBytesArchive: Int64,
        git: Git,
        restoreHint: String?,
        historicalPaths: [String]? = nil,
        continuity: Continuity? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.archivedAt = archivedAt
        self.archivedBy = archivedBy
        self.originalPath = originalPath
        self.sizeBytesBefore = sizeBytesBefore
        self.sizeBytesArchive = sizeBytesArchive
        self.git = git
        self.restoreHint = restoreHint
        self.historicalPaths = historicalPaths ?? [originalPath]
        self.continuity = continuity
    }

    public static let currentSchemaVersion = 2

    /// Every schema this build can read. Restore checks membership, not
    /// equality: bumping the writer must never strand archives the user
    /// already made, and those archives are the only copy of a workspace
    /// that has since been trashed.
    public static let supportedSchemaVersions: ClosedRange<Int> = 1...2

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

// MARK: - Cross-version decoding

extension ArchiveManifest {
    /// Hand-written so a v1 sidecar — written before sessions were a
    /// concept — still decodes into the current type instead of failing
    /// on two keys it could not have contained. One decoder for both
    /// versions, rather than a v1 type plus a migration step: the two
    /// schemas differ only by fields that have a correct default, and a
    /// parallel legacy type would have to be kept in sync forever for no
    /// added fidelity.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let originalPath = try c.decode(String.self, forKey: .originalPath)
        self.init(
            schemaVersion: try c.decode(Int.self, forKey: .schemaVersion),
            archivedAt: try c.decode(Date.self, forKey: .archivedAt),
            archivedBy: try c.decode(String.self, forKey: .archivedBy),
            originalPath: originalPath,
            sizeBytesBefore: try c.decode(Int64.self, forKey: .sizeBytesBefore),
            sizeBytesArchive: try c.decode(Int64.self, forKey: .sizeBytesArchive),
            git: try c.decode(Git.self, forKey: .git),
            restoreHint: try c.decodeIfPresent(String.self, forKey: .restoreHint),
            // A v1 manifest knows exactly one path, and it is this one.
            historicalPaths: try c.decodeIfPresent([String].self, forKey: .historicalPaths),
            // Deliberately left nil for v1 rather than synthesised as an
            // empty assessment: "this archive predates the question" and
            // "a binder ran and found nothing" are different facts.
            continuity: try c.decodeIfPresent(Continuity.self, forKey: .continuity)
        )
    }
}
