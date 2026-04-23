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
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(run.results) { result in
                        HStack(spacing: 8) {
                            statusIcon(for: result)
                            Text(result.repoPath.lastPathComponent).lineLimit(1)
                            Spacer()
                            if let err = result.failure {
                                Text(String(describing: err))
                                    .font(.caption).foregroundStyle(.red).lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 4)
                    }
                }
            }
            .frame(maxHeight: 200)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder
    private func statusIcon(for result: PerRepoResult) -> some View {
        if result.success != nil {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if result.failure != nil {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        } else {
            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        }
    }
}
