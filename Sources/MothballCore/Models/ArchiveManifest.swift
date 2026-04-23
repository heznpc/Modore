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

    public struct Git: Codable, Sendable, Equatable {
        public let origin: String?
        public let branch: String?
        public let headSHA: String?
        public let lastCommitDate: Date?
        public let aheadOfOrigin: Int?
        public let wasDirty: Bool
    }

    public static let currentSchemaVersion = 1

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
