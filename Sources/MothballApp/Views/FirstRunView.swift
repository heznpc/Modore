import SwiftUI

struct FirstRunView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Mothball")
                .font(.system(size: 38, weight: .semibold))
            Text("오래된 git 프로젝트를 안전하게 보관하고 디스크를 비웁니다.")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 14) {
                promise(
                    "선택한 폴더만 읽습니다.",
                    detail: "Full Disk Access 권한을 요구하지 않습니다. 직접 추가한 경로 외에는 접근하지 않습니다."
                )
                promise(
                    "원본은 즉시 삭제하지 않습니다.",
                    detail: "압축본 검증이 끝난 뒤에만 원본을 휴지통으로 보냅니다. 휴지통을 비우기 전까지 복구할 수 있습니다."
                )
                promise(
                    "네트워크 접근은 옵션입니다.",
                    detail: "기본 동작은 로컬 git 정보만 사용합니다. 'fetch 후 검증'을 켰을 때만 외부와 통신합니다."
                )
            }
            .frame(maxWidth: 540, alignment: .leading)
            .padding(20)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

            Spacer()

            Button {
                model.hasAcceptedFirstRun = true
            } label: {
                Text("동의하고 시작")
                    .frame(width: 200, height: 28)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }

    private func promise(_ headline: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
