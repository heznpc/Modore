import SwiftUI

struct RecoveryHistorySection: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        Section {
            if let error = model.recoveryHistoryError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            if model.recoveryHistory.isEmpty {
                Text("저장된 공간 확보 계획이 없습니다. 계획을 검토하면 목표와 대상부터 기록됩니다.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.recoveryHistory) { record in
                RecoveryHistoryRow(record: record)
            }
        } header: {
            NativeSectionHeader(title: "공간 확보 계획 이력",
                                subtitle: "목표·승인·실행 결과를 함께 보존합니다. 과거 기록은 실행 권한이 아니며 자동 재실행하지 않습니다.",
                                value: "\(model.recoveryHistory.count)개 계획")
        }
    }
}

private struct RecoveryHistoryRow: View {
    let record: RecoveryHistory

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text("기준 여유 \(StorageBytes.text(record.baselineFreeBytes)) · 추가 목표 \(StorageBytes.text(record.requestedGainBytes)) · 최종 목표 \(StorageBytes.text(record.desiredFreeBytes))")
                Text("최종 여유 \(StorageBytes.text(record.finalFreeBytes)) · 순변화 \(StorageBytes.changeText(record.actualChangeBytes))")
                if let approvedAt = record.approvedAt {
                    Text("승인 \(approvedAt.formatted(date: .abbreviated, time: .standard)) · 승인 대상 \(record.entries.filter(\.ready).count)개")
                } else {
                    Text("승인되지 않은 계획입니다.")
                }
                if !record.detail.isEmpty { Text(record.detail) }
                ForEach(record.entries) { entry in
                    entryDetail(entry)
                }
                Text("계획 ID \(record.id.uuidString)")
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                Text("최종 기록 \(record.updatedAt.formatted(date: .abbreviated, time: .standard)) · 다시 실행하려면 목표 화면에서 새로 측정하고 승인하세요.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("추가 \(StorageBytes.text(record.requestedGainBytes)) · \(record.goalMet ? "목표 달성" : record.phase.title)")
                    .font(.body.weight(.medium))
                Text("\(record.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(record.items.count)/\(record.entries.filter(\.ready).count)개 결과 기록")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func entryDetail(_ entry: RecoveryHistory.Entry) -> some View {
        let item = record.items.first { $0.id == entry.id }
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(entry.label) · \(item?.status ?? (record.activeEntryID == entry.id ? "실행 결과 미확인" : (entry.ready ? "실행 기록 없음" : entry.previewStatus)))")
                .fontWeight(.medium)
            Text("미리보기 점유 \(StorageBytes.text(entry.estimatedBytes))")
            ForEach(Array(entry.targets.enumerated()), id: \.offset) { _, path in
                Text(path).textSelection(.enabled)
            }
            if let item {
                Text("대상 감소 \(StorageBytes.text(item.reclaimedBytes)) · 볼륨 순변화 \(StorageBytes.changeText(item.physicalDeltaBytes))")
                if !item.detail.isEmpty { Text(item.detail) }
                if !item.receipt.isEmpty { Text("영수증 \(item.receipt)").textSelection(.enabled) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
