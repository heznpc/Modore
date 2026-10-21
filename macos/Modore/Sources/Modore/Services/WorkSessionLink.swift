import Foundation

/// Navigation identity only. It is never an account assignment, resume approval,
/// filesystem path, or permission to restore/remove a workspace.
struct WorkSessionLink: Hashable, Sendable {
    let provider: String
    let sessionID: String

    init?(provider: String, sessionID: String) {
        guard provider == "codex", let id = UUID(uuidString: sessionID) else { return nil }
        self.provider = provider
        self.sessionID = id.uuidString.lowercased()
    }

    init?(session: SessionIndexEntry) {
        guard session.kind == "session", let id = session.providerSessionId else { return nil }
        self.init(provider: session.tool.lowercased(), sessionID: id)
    }

    var quotaPieURL: URL { URL(string: "quotapie://session/\(sessionID)")! }

    func resolve(in sessions: [SessionIndexEntry]) -> SessionIndexEntry? {
        // The index already consolidates physical fragments. If it still
        // contains multiple logical rows, do not pick a profile by recency.
        let matches = sessions.filter { Self(session: $0) == self }
        return matches.count == 1 ? matches.first : nil
    }
}
