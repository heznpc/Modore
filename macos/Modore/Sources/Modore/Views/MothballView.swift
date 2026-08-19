import SwiftUI
import MothballCore

/// Displays MothballCore's judgment about which of scree's already-known
/// workspace paths are dormant, git-clean, mostly-pushed repos worth
/// archiving. Read-only, mirroring scree's own first exposure to this app:
/// this page never compresses, moves, or deletes anything.
struct MothballPage: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        Form {
            Section {
                if model.screeReport == nil {
                    HStack(spacing: 12) {
                        Image(systemName: "clock.badge.questionmark")
                            .foregroundStyle(Color.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AI 세션 감사를 먼저 실행하세요")
                                .font(.body.weight(.medium))
                            Text("보관 후보는 AI 세션이 기록한 작업 경로 중 git 저장소만 찾습니다.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } else if model.archiveLoading {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("git 저장소 확인 중…")
                            .foregroundStyle(.secondary)
                    }
                } else if let error = model.archiveError {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Color.secondary)
                            .frame(width: 20)
                        Text(error)
                            .foregroundStyle(.secondary)
                    }
                } else if model.archiveCandidates == nil {
                    Text("git 메타데이터(마지막 커밋, dirty 여부, 푸시 상태)만으로 판정합니다. 아무것도 압축·삭제하지 않습니다.")
                        .foregroundStyle(.secondary)
                }
                Button(model.archiveCandidates == nil ? "지금 스캔" : "다시 스캔") {
                    model.refreshArchiveCandidates()
                }
                .disabled(model.archiveLoading || model.screeReport == nil)
            } header: {
                NativeSectionHeader(
                    title: "레포 은퇴 후보",
                    subtitle: "오래 안 쓴 저장소와, 그 저장소를 지우면 함께 끊기는 AI 대화를 함께 판정합니다.",
                    value: model.archiveCandidates != nil ? "완료" : ""
                )
            }

            if let candidates = model.archiveCandidates {
                MothballCandidateSection(
                    candidates: candidates,
                    inspectionFailures: model.archiveInspectionFailures,
                    preserveInFlightSource: model.screePreserveInFlightSource,
                    onPreserve: { model.preserveBoundSession($0) }
                )
            }
        }
        .macSettingsFormStyle()
    }
}

struct MothballCandidateSection: View {
    let candidates: [ArchiveCandidate]
    let inspectionFailures: Int
    /// Passed in rather than read from the environment: this section is
    /// otherwise pure display data, and keeping the one mutating action
    /// explicit at the call site keeps it that way.
    let preserveInFlightSource: String?
    let onPreserve: (SessionBinding) -> Void

    var body: some View {
        Section {
            if candidates.isEmpty {
                // "None found" and "could not look" are different answers.
                Text(inspectionFailures > 0
                    ? "저장소 \(inspectionFailures)개를 검사하지 못해 보관 후보를 판단할 수 없습니다."
                    : "보관할 만한 저장소가 없습니다.")
                    .foregroundStyle(.secondary)
            } else if inspectionFailures > 0 {
                Text("저장소 \(inspectionFailures)개는 검사하지 못했습니다. 아래 목록은 확인된 것만입니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(candidates) { candidate in
                if candidate.boundSessions.isEmpty {
                    candidateSummary(candidate)
                } else {
                    // Expandable only when there is something to expand
                    // into. A disclosure arrow on a row that opens to
                    // nothing teaches the user to stop pressing them.
                    DisclosureGroup {
                        boundSessionList(candidate)
                    } label: {
                        candidateSummary(candidate)
                    }
                }
            }
        } header: {
            NativeSectionHeader(
                title: "후보",
                // The one number that decides anything on this page. The
                // previous subtitle said only where the feature *isn't*,
                // which is not something the reader can act on.
                subtitle: Self.boundSummary(candidates),
                value: candidates.isEmpty ? "" : "\(candidates.count)개"
            )
        }
    }

    @ViewBuilder
    private func candidateSummary(_ candidate: ArchiveCandidate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: candidate.tierSymbolName)
                .foregroundStyle(Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.pathLastComponent)
                    .font(.body.weight(.medium))
                Text("\(candidate.reasonText) · \(candidate.sizeText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // The line this whole feature exists for. A repo with
                // bound conversations and one without are the same git
                // tier, and until now the row said nothing that told
                // them apart.
                Text(candidate.continuityText)
                    .font(.caption)
                    .foregroundStyle(candidate.hasUnsealedSessions ? Color.orange : Color.secondary)
            }
            Spacer()
            // The tier is already in the icon, and on a machine that uses
            // agents every candidate lands on the same tier -- fifty-three
            // rows all reading "주의 필요" sort nothing and cost a scan.
            // The trailing slot goes to the number that actually differs.
            Text(candidate.trailingLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(candidate.hasUnsealedSessions ? Color.orange : Color.secondary)
        }
    }

    /// The bound conversations themselves.
    ///
    /// A count and a size establish that deleting costs something; they
    /// do not say what. Only the transcript does, and the person about to
    /// approve the delete is the one who has to judge it -- so the export
    /// is reachable here rather than only from the session page. It goes
    /// through scree's existing `preserve`: one explicitly named session,
    /// masked by default, which is the only sanctioned way content leaves
    /// a store.
    @ViewBuilder
    private func boundSessionList(_ candidate: ArchiveCandidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(candidate.boundSessions.prefix(Self.boundSessionDisplayLimit), id: \.sessionID) { binding in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(binding.provider.rawValue) · \(binding.sessionID)")
                            .font(.caption.monospaced())
                        Text(Self.evidenceText(binding))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if preserveInFlightSource == binding.source.path {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("내용 보기") { onPreserve(binding) }
                            .buttonStyle(.link)
                            .font(.caption)
                            .disabled(preserveInFlightSource != nil)
                    }
                }
            }
            if candidate.boundSessions.count > Self.boundSessionDisplayLimit {
                // Say what was cut rather than ending the list silently:
                // a truncated list reads as a complete one.
                Text("외 \(candidate.boundSessions.count - Self.boundSessionDisplayLimit)개는 표시하지 않았습니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 32)
        .padding(.top, 4)
    }

    /// What the whole list amounts to, stated once at the top.
    ///
    /// Every row here already carries a tier label, and on a machine that
    /// uses agents heavily every row reads the same -- so the label sorts
    /// nothing and the reader has to scan 53 identical lines to learn the
    /// only fact that varies. This says it up front instead.
    static func boundSummary(_ candidates: [ArchiveCandidate]) -> String {
        let withSessions = candidates.filter { !$0.boundSessions.isEmpty }
        guard !withSessions.isEmpty else {
            return "연결된 AI 대화가 있는 저장소는 없습니다."
        }
        let sessions = withSessions.reduce(0) { $0 + $1.boundSessions.count }
        let bytes = withSessions.reduce(Int64(0)) { total, candidate in
            total + candidate.boundSessions.reduce(Int64(0)) { $0 + $1.sizeBytes }
        }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "\(withSessions.count)개 저장소에 AI 대화 \(sessions)개(\(size))가 묶여 있습니다. 지우면 함께 끊깁니다."
    }

    /// Long enough to browse, short enough that a 120-session repo does
    /// not turn one row into a page.
    static let boundSessionDisplayLimit = 20

    static func evidenceText(_ binding: SessionBinding) -> String {
        let evidence = binding.evidence.map { evidenceLabel($0) }.joined(separator: " · ")
        let size = ByteCountFormatter.string(fromByteCount: binding.sizeBytes, countStyle: .file)
        return "\(evidence) · \(confidenceLabel(binding.confidence)) · \(size)"
    }

    private static func evidenceLabel(_ evidence: BindingEvidence) -> String {
        switch evidence {
        case .remoteURL: return "원격 URL 기록됨"
        case .workingDirectory: return "작업 디렉터리 일치"
        case .fileAccess: return "파일 접근 기록"
        }
    }

    private static func confidenceLabel(_ confidence: BindingConfidence) -> String {
        switch confidence {
        case .high: return "확실"
        case .medium: return "보통"
        case .low: return "약함"
        }
    }
}
