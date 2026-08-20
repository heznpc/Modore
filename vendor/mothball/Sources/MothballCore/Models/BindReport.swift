import Foundation

/// Wire format of `scree.py bind`, and the one place a binder's answer
/// crosses a process boundary.
///
/// The boundary is why `assessed` is a field at all. In-process, the
/// difference between "a binder ran and found nothing" and "no binder
/// ran" is carried by which `ContinuityAssessment` case you construct.
/// Across a pipe there are no cases — only JSON — and an empty
/// `bindings` array looks identical in both situations. So the binder
/// states it explicitly, and this decoder refuses to guess: anything it
/// cannot read as a completed assessment becomes `.notAssessed`, which
/// blocks.
public struct BindReport: Codable, Sendable, Equatable {
    public let workspace: String
    public let repoUrl: String?
    public let assessed: Bool
    public let deep: Bool?

    /// How much of the store was examined: `"shallow"`, `"truncated"`,
    /// or `"complete"`.
    ///
    /// Separate from `assessed`, which only says the run finished, and
    /// separate again from how hard it tried. A shallow pass matches
    /// recorded working directories, so an empty result means no session
    /// *ran* in this workspace -- not that none touched it. A truncated
    /// pass tried and could not conclude: a content scan that stopped
    /// early, a transcript that would not open, a store whose identity
    /// data is missing.
    ///
    /// `complete` means every candidate was conclusively classified --
    /// decided by metadata authoritative enough on its own, or read to
    /// EOF and found not to mention the workspace. Not "every byte was
    /// read": a session already bound by its header gains nothing from
    /// being read again, and editor entries have no transcript body at
    /// all. Only `complete` makes emptiness a finding.
    public let coverage: String?

    /// Why a pass fell short of `complete`, per store. Carried so a
    /// consumer can name the gap -- an unreadable rollout is closed by
    /// fixing permissions, a store with no binder is closed by writing
    /// one, and "incomplete" alone tells the user neither.
    public let coverageDetail: CoverageDetail?

    public struct CoverageDetail: Codable, Sendable, Equatable {
        public let claude: String?
        public let codex: String?
        /// Session stores present on this machine that no binder reads.
        /// The loudest incompleteness there is: the scan never looked.
        public let unboundStores: [String]?
    }
    public let bindings: [Entry]

    public struct Entry: Codable, Sendable, Equatable {
        public let provider: String
        public let sessionId: String
        public let source: String
        public let subtranscripts: [String]
        /// Directory `subtranscripts` are relative to, when the binder
        /// knows it. Absent for stores whose layout the fallback covers.
        public let artifactRoot: String?
        public let evidence: [String]
        public let confidence: String
        public let sizeBytes: Int64
    }

    public static func decoder() -> JSONDecoder { JSONDecoder() }
}

extension ContinuityAssessment {

    /// Turns one `scree.py bind` payload into an assessment.
    ///
    /// Unparseable input is `.notAssessed`, not an error the caller might
    /// be tempted to ignore and continue past: a malformed binder report
    /// is indistinguishable from no binder report, and both mean nobody
    /// established what would be stranded.
    public static func fromBindReport(_ data: Data) -> ContinuityAssessment {
        guard let report = try? BindReport.decoder().decode(BindReport.self, from: data),
              report.assessed else {
            return .notAssessed
        }
        let bindings = report.bindings.compactMap(SessionBinding.init(entry:))
        // A binder that returned entries none of which survive decoding
        // has not established "no sessions" — it has produced something
        // this build cannot read, which is the `notAssessed` case again.
        guard bindings.count == report.bindings.count else { return .notAssessed }
        let coverage = BindingCoverage(reported: report.coverage)
        if bindings.isEmpty {
            // Emptiness is only a finding when the pass could have seen
            // every session that might mention this workspace. Anything
            // less -- matched no directories, or read bodies and stopped
            // early -- reports what it is: nobody has established this
            // workspace is conversation-free, which blocks.
            return coverage == .complete ? .assessedNoSessions : .notAssessed
        }
        // Coverage travels with the bindings rather than being consulted
        // only when the list is empty. Finding one session says nothing
        // about the ones a shallow pass could not see, and a model that
        // drops the distinction here lets a partial scan seal what it
        // found and call the workspace handled.
        return .bindings(bindings, coverage: coverage)
    }
}

extension SessionBinding {
    /// `nil` for an entry naming a provider this build does not know.
    /// Dropping it silently would shrink the binding set, and a smaller
    /// set is exactly what makes a workspace look safer than it is — so
    /// `fromBindReport` treats any loss as a failed assessment rather
    /// than a smaller success.
    init?(entry: BindReport.Entry) {
        guard let provider = SessionProvider(rawValue: entry.provider),
              let confidence = BindingConfidence(rawValue: entry.confidence) else {
            return nil
        }
        let evidence = entry.evidence.compactMap(BindingEvidence.init(rawValue:))
        guard evidence.count == entry.evidence.count else { return nil }
        self.init(
            provider: provider,
            sessionID: entry.sessionId,
            source: URL(fileURLWithPath: entry.source),
            subtranscripts: entry.subtranscripts.map { URL(fileURLWithPath: $0) },
            artifactRoot: entry.artifactRoot.map { URL(fileURLWithPath: $0) },
            evidence: evidence,
            confidence: confidence,
            sizeBytes: entry.sizeBytes
        )
    }
}
