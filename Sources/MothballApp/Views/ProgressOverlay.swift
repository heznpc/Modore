import SwiftUI

struct ProgressOverlay: View {
    @ObservedObject var run: ArchiveRun

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("아카이브 진행 중").font(.title2).bold()

            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(run.completedCount), total: Double(run.total))
                Text("\(run.completedCount) / \(run.total)").font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(run.currentRepoName).font(.headline).lineLimit(1)
                Text(run.currentStep.localizedLabel).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .liquidGlassCard(cornerRadius: 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(run.results) { result in
                        HStack(spacing: 8) {
                            statusIcon(for: result)
                            Text(result.repoPath.lastPathComponent).lineLimit(1)
                            Spacer()
                            if let err = result.failure {
                                Text(err.localizedDescription)
                                    .font(.caption).foregroundStyle(.red).lineLimit(1)
                            } else if result.wasSkipped {
                                Text("중단됨")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 4)
                    }
                }
            }
            .frame(maxHeight: 200)
            .liquidGlassCard(cornerRadius: 10)

            HStack {
                if run.isCancellationRequested {
                    Text("현재 저장소 처리 후 중단합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(run.isCancellationRequested ? "중단 대기 중" : "현재 저장소 후 중단") {
                    run.requestCancellation()
                }
                .disabled(run.isCancellationRequested || run.isFinished)
                .liquidSecondaryActionStyle()
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled(!run.isFinished)
    }

    @ViewBuilder
    private func statusIcon(for result: PerRepoResult) -> some View {
        if result.success != nil {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if result.wasSkipped {
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        } else if result.failure != nil {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        } else {
            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        }
    }
}
