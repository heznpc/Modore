import SwiftUI

struct ArchiveSummaryView: View {
    let summary: ArchiveSummary
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(summary.skipped > 0 ? "아카이브 중단됨" : "아카이브 완료")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 8) {
                metric("시도", "\(summary.attempted)개")
                metric("성공", "\(summary.succeeded)개")
                metric("실패", "\(summary.failed)개")
                if summary.skipped > 0 {
                    metric("건너뜀", "\(summary.skipped)개")
                }
                metric("순 회수 예상", summary.bytesFreed.fileSizeString)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(summary.results) { result in
                        ArchiveSummaryRow(result: result)
                    }
                }
            }
            .frame(maxHeight: 240)
            .liquidGlassCard(cornerRadius: 10)

            HStack {
                Spacer()
                Button("닫기") {
                    model.dismissArchiveSummary()
                }
                .keyboardShortcut(.defaultAction)
                .liquidProminentActionStyle()
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .monospacedDigit()
        }
    }
}

private struct ArchiveSummaryRow: View {
    let result: PerRepoResult

    var body: some View {
        HStack(spacing: 8) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(result.repoPath.lastPathComponent)
                    .lineLimit(1)
                if let message = detail {
                    detailText(message)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var icon: some View {
        if result.success != nil {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if result.wasSkipped {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var detail: String? {
        if let error = result.failure {
            return error.localizedDescription
        }
        if result.wasSkipped {
            return "사용자 요청으로 실행하지 않음"
        }
        if let success = result.success {
            return "아카이브 \(success.archive.lastPathComponent)"
        }
        return nil
    }

    @ViewBuilder
    private func detailText(_ message: String) -> some View {
        if result.failure == nil {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        } else {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}
