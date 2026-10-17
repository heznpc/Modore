import SwiftUI

/// Supplemental observations remain dated evidence, never approval or current totals.
struct StorageSupplementalAuditView: View {
    let audit: SupplementalStorageAudit?
    var body: some View {
        Group {
            if let audit {
                DisclosureGroup(L10n.format("별도 조사 기록 · %@", String(describing: audit.date.formatted(date: .abbreviated, time: .shortened)))) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.format("범위: %@ · %@행 · 미측정 %@행", String(describing: audit.roots.joined(separator: ", ")), String(describing: audit.rows), String(describing: audit.unmeasured)))
                        Text(L10n.text("제한된 범위의 과거 관측입니다. 현재 조사 합계나 정리 승인에 합산하지 않습니다."))
                        ForEach(audit.paths, id: \.path) { row in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\((row.path as NSString).abbreviatingWithTildeInPath) · \(StorageBytes.text(row.bytes))")
                                    .fontWeight(.medium)
                                Text("\(L10n.message(row.classification)) · \(L10n.message(row.evidence))")
                                Text(L10n.message(row.usage))
                            }
                        }
                        ForEach(audit.contentDetails, id: \.self) { Text(L10n.message($0)) }
                    }.padding(.vertical, 8).textSelection(.enabled)
                }
            }
        }
    }
}
