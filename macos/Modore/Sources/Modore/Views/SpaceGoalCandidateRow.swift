import AppKit
import SwiftUI

struct SpaceGoalCandidateRow: View {
    @EnvironmentObject private var model: ScanModel
    let item: StorageItem
    let evidence: StorageInvestigation?
    let judgment: StorageJudgment
    let scanDate: Date?
    @Binding var isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                if judgment == .ready {
                    Toggle("선택", isOn: $isSelected).labelsHidden().toggleStyle(.checkbox)
                        .accessibilityLabel("\(item.label) 정리 대상으로 선택").disabled(model.isBusy)
                }
                NativeSourceIcon(item: item, fallbackSymbol: "folder")
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.label).font(.body.weight(.semibold))
                    Text((item.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(size).font(.callout.weight(.medium)).monospacedDigit()
                    Text(evidence == nil ? (item.measureStatus == "historical" ? "과거 조사 경로" : "검사 당시") : (evidence?.bytes == nil ? "조사 미완료" : "조사 실측")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text("사용 확인: \(evidence?.usage ?? "현재 사용 상태 미확인")")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("재생성: \(evidence?.regeneration ?? "근거 미확인 · 내용 검토 필요")")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            DisclosureGroup("근거 상세 · \((evidence?.date ?? scanDate)?.formatted(date: .abbreviated, time: .shortened) ?? "측정 시각 미확인")") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(evidence?.reason ?? (item.hasSupportedCleanupRecipe ? "조사 후 판단할 수 있습니다." : "일괄 정리 대상이 아닙니다. 보존 자료와 재설치 필요성을 확인하세요."))
                    Text("열린 파일이 관측되지 않아도 미사용을 확정하지 않습니다. 실행 직전에 다시 확인합니다.")
                    Text(evidence?.regeneration ?? "재생성 근거 미확인")
                    if let evidence, !evidence.impact.isEmpty { Text("정리 영향·주의: \(evidence.impact)") }
                    else if !item.note.isEmpty { Text("검사 안내: \(item.note)") }
                    ForEach(evidence?.targets ?? [], id: \.self) { Text("조사 대상: \($0)") }
                    ForEach(evidence?.preserved ?? [], id: \.self) { Text("보존 경로: \($0)") }
                }.textSelection(.enabled).padding(.vertical, 6)
            }.font(.caption)
            if judgment != .ready {
                HStack {
                    if item.hasSupportedCleanupRecipe {
                        if evidence?.issue == .access {
                            Button("접근 설정 열기") { model.openFullDiskAccessSettings() }
                        }
                        Button(retryTitle) { model.investigateStorage([item]) }.disabled(model.isBusy)
                        if item.cleanupTier == nil {
                            Button("개별 제거 검토…") { model.prepareCleanup(item) }.disabled(model.isBusy)
                        }
                    }
                    Button("Finder에서 보기") { NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "") }
                    Spacer()
                    if let issue = evidence?.issue { Text(issue.title).foregroundStyle(.secondary) }
                }.font(.caption)
            }
        }.padding(.vertical, 12)
    }
    private var size: String {
        if let evidence { return StorageBytes.text(evidence.bytes) }
        return item.measureStatus == "ok" ? StorageBytes.text(StorageBytes.fromLegacyGiB(item.sizeGB)) : "크기 미확인"
    }
    private var retryTitle: String {
        if judgment == .inUse { return "작업 종료 후 다시 조사" }
        if evidence?.issue == .access { return "접근 허용 후 다시 조사" }
        return evidence?.issue?.action ?? "이 항목 조사"
    }
}
