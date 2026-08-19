import SwiftUI

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
                    title: "저장소 보관 후보",
                    subtitle: "git 메타데이터만으로 판정한 미리보기입니다. 압축·보관 실행은 아직 없습니다.",
                    value: model.archiveCandidates != nil ? "완료" : ""
                )
            }

            if let candidates = model.archiveCandidates {
                MothballCandidateSection(
                    candidates: candidates,
                    inspectionFailures: model.archiveInspectionFailures
                )
            }
        }
        .macSettingsFormStyle()
    }
}

private struct MothballCandidateSection: View {
    let candidates: [ArchiveCandidate]
    let inspectionFailures: Int

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
                    }
                    Spacer()
                    Text(candidate.tierLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.secondary)
                }
            }
        } header: {
            NativeSectionHeader(
                title: "후보 목록",
                subtitle: "압축 후 원본 삭제는 아직 어디에서도 실행되지 않습니다. 실행이 붙으면 다른 삭제 작업과 같이 미리보기·승인 절차를 거칩니다.",
                value: candidates.isEmpty ? "" : "\(candidates.count)개"
            )
        }
    }
}
