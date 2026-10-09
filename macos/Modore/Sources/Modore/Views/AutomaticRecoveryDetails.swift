import AppKit
import SwiftUI

struct AutomaticRecoveryDetails: View {
    let report: AutomaticCacheReport
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let candidates = report.candidates, !candidates.isEmpty {
                DisclosureGroup("항목별 정리 가능 여부") {
                    ScrollView {
                        ForEach(candidates.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }) { item in
                            VStack(alignment: .leading) {
                                Text("\(item.label) · \(item.bytes.map { HealthSnapshot.bytes($0) } ?? "용량 미확인")")
                                Text(item.reason).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.frame(maxHeight: 180)
                }
            }
            if let occupants = report.occupants, !occupants.isEmpty {
                DisclosureGroup("남은 큰 점유 항목 · 확보 가능한 용량과 다릅니다") {
                    Text("측정 시점: \(report.analysisAt?.formatted() ?? "확인 필요")").font(.caption)
                    ScrollView {
                        ForEach(occupants) { item in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("\(item.label) · \(HealthSnapshot.bytes(item.bytes))\(item.complete ? "" : " 이상 · 부분 측정")")
                                    Text(item.path).font(.caption).textSelection(.enabled)
                                }
                                Spacer()
                                Button("경로 열기") {
                                    NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                                }.accessibilityLabel("\(item.label) 경로 열기")
                            }
                        }
                    }.frame(maxHeight: 180)
                }
            }
        }
    }
}
