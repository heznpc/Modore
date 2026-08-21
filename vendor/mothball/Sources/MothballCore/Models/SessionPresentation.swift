import Foundation

/// Where a session's title came from.
///
/// Not decoration. A title lifted from the first real request and one
/// shaped from a file's timestamp look alike in a list and mean very
/// different things, and only the surface showing them can decide
/// whether to admit the difference. A caller that drops this ends up
/// presenting a guess with the same confidence as a quotation.
public enum TitleSource: String, Codable, Sendable, Hashable {
    /// The provider stored a title of its own.
    case providerNative = "provider-native"
    /// The first user turn that asked for something.
    case firstRequest = "first-request"
    /// Every request was a resumption marker; this is the first of them.
    case resumption
    /// Nothing recognisable as a request; the last thing said.
    case recentTurn = "recent-turn"
    /// Nothing readable at all. Shaped from the file's date.
    case date

    /// Whether a reader should be told the title is inferred. A quoted
    /// request speaks for itself; a date-shaped label does not.
    public var isWeak: Bool {
        switch self {
        case .providerNative, .firstRequest: return false
        case .resumption, .recentTurn, .date: return true
        }
    }
}

/// What a person needs to recognise a conversation, separate from what
/// the gate needs to decide whether deleting is safe.
///
/// Deliberately not folded into `SessionBinding`. That type is evidence:
/// which store recorded what, how firmly, hashed and verifiable. This
/// one is lossy, guessed, and occasionally wrong -- a title can be the
/// first line of a request that turned out to be about something else.
/// Nothing that decides whether a workspace may be deleted is allowed to
/// rest on it, and keeping the two in one struct is how that rule gets
/// broken by accident later.
public struct SessionPresentation: Sendable, Equatable, Identifiable {
    public let provider: SessionProvider
    public let sessionID: String
    public let title: String
    public let titleSource: TitleSource
    public let lastActiveAt: Date?
    public let sizeBytes: Int64

    public var id: String { "\(provider.rawValue)/\(sessionID)" }

    public init(
        provider: SessionProvider,
        sessionID: String,
        title: String,
        titleSource: TitleSource,
        lastActiveAt: Date?,
        sizeBytes: Int64
    ) {
        self.provider = provider
        self.sessionID = sessionID
        self.title = title
        self.titleSource = titleSource
        self.lastActiveAt = lastActiveAt
        self.sizeBytes = sizeBytes
    }

    /// Editors remembered a folder; agents held a conversation. Saying
    /// "대화" for both overstates what a VS Code workspace entry is.
    public var kindLabel: String {
        provider.keepsTranscripts ? "대화" : "편집기 상태"
    }
}

/// Identity of the bytes a title was read from.
///
/// `mtime` and `size` alone miss a transcript rewritten to the same
/// length, which is exactly what a compaction or a truncated rewrite
/// produces. The file's own identity closes that, and the provider and
/// session id keep two stores that number sessions alike apart.
public struct PresentationCacheKey: Hashable, Sendable {
    public let provider: SessionProvider
    public let sessionID: String
    public let fileIdentity: String
    public let modifiedAt: Date
    public let sizeBytes: Int64

    public init?(provider: SessionProvider, sessionID: String, source: URL) {
        let keys: Set<URLResourceKey> = [
            .fileResourceIdentifierKey, .contentModificationDateKey, .fileSizeKey,
        ]
        // Read through a fresh URL, never the caller's. `URL` memoises
        // resource values per instance after the first fetch, so a
        // long-lived URL -- which is the normal case here, since a screen
        // holds its bindings for its whole lifetime -- keeps answering
        // with the size and mtime the file had when it was first looked
        // at. That silently defeats this type's entire purpose: a
        // transcript an agent is still appending to would keep its
        // original key and read as unchanged forever.
        let uncached = URL(fileURLWithPath: source.path)
        guard let values = try? uncached.resourceValues(forKeys: keys),
              let identifier = values.fileResourceIdentifier,
              let modified = values.contentModificationDate,
              let size = values.fileSize else {
            return nil
        }
        self.provider = provider
        self.sessionID = sessionID
        self.fileIdentity = String(describing: identifier)
        self.modifiedAt = modified
        self.sizeBytes = Int64(size)
    }
}
