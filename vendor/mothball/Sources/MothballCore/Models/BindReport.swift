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
    public let bindings: [Entry]

    public struct Entry: Codable, Sendable, Equatable {
        public let provider: String
        public let sessionId: String
        public let source: String
        public let subtranscripts: [String]
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
        if bindings.isEmpty {
            return report.bindings.isEmpty ? .assessedNoSessions : .notAssessed
        }
        return .bindings(bindings)
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
            evidence: evidence,
            confidence: confidence,
            sizeBytes: entry.sizeBytes
        )
    }
}
