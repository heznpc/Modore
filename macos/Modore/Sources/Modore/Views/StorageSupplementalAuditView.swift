import SwiftUI

/// Supplemental observations remain dated evidence, never approval or current totals.
struct StorageSupplementalAuditView: View {
    let audit: SupplementalStorageAudit?
    var body: some View {
        Group {
            if let audit {
                DisclosureGroup("별도 조사 기록 · \(audit.date.formatted(date: .abbreviated, time: .shortened))") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("범위: \(audit.roots.joined(separator: ", ")) · \(audit.rows)행 · 미측정 \(audit.unmeasured)행")
                        Text("제한된 범위의 과거 관측입니다. 현재 조사 합계나 정리 승인에 합산하지 않습니다.")
                        ForEach(audit.paths, id: \.path) { row in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\((row.path as NSString).abbreviatingWithTildeInPath) · \(StorageBytes.text(row.bytes))")
                                    .fontWeight(.medium)
                                Text("\(row.classification) · \(row.evidence)")
                                Text(row.usage)
                            }
                        }
                        ForEach(audit.contentDetails, id: \.self) { Text($0) }
                    }.padding(.vertical, 8).textSelection(.enabled)
                }
            }
        }
    }
}
