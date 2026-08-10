import SwiftUI

struct ConfirmView: View {
    let request: ConfirmRequest
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("아카이브 확인").font(.title2).bold()

            VStack(alignment: .leading, spacing: 8) {
                row("저장소", "\(request.repos.count)개")
                row("회수 예상", request.totalBytes.fileSizeString)
                row("저장 위치", request.archiveDirectory.path)
            }

            if request.hasCautionItems {
                CautionBanner(count: request.cautionCount)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(request.repos) { repo in
                        HStack {
                            TierBadge(verdict: repo.verdict)
                            Text(repo.info.path.lastPathComponent)
                            Spacer()
                            Text(repo.info.sizeBytes.fileSizeString)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                }
            }
            .frame(maxHeight: 240)
            .liquidGlassCard(cornerRadius: 10)

            HStack {
                Spacer()
                Button("취소") { model.cancelConfirmation() }
                    .keyboardShortcut(.cancelAction)
                    .liquidSecondaryActionStyle()
                Button("아카이브 실행") { model.confirmAndStartArchive() }
                    .keyboardShortcut(.defaultAction)
                    .liquidProminentActionStyle()
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
    }
}

struct CautionBanner: View {
    let count: Int
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count)개 저장소에 origin에 push되지 않은 변경이 있습니다.")
                    .font(.callout).bold()
                Text("아카이브 안에는 그대로 포함되지만, origin에서 다시 받을 수는 없습니다. 미푸시 커밋이 중요한 작업이라면 아카이브 전에 push하세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .liquidCautionCard(cornerRadius: 10)
    }
}
