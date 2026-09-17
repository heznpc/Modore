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
                Text(L10n.text("저장된 공간 확보 계획이 없습니다. 계획을 검토하면 목표와 대상부터 기록됩니다."))
                    .foregroundStyle(.secondary)
            }
            ForEach(model.recoveryHistory) { record in
                RecoveryHistoryRow(record: record)
            }
        } header: {
            NativeSectionHeader(title: L10n.text("공간 확보 계획 이력"),
                                subtitle: L10n.text("목표·승인·실행 결과를 함께 보존합니다. 과거 기록은 실행 권한이 아니며 자동 재실행하지 않습니다."),
                                value: L10n.format("%@개 계획", String(describing: model.recoveryHistory.count)))
        }
    }
}

private struct RecoveryHistoryRow: View {
    let record: RecoveryHistory

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.format("기준 여유 %@ · 추가 목표 %@ · 최종 목표 %@", String(describing: StorageBytes.text(record.baselineFreeBytes)), String(describing: StorageBytes.text(record.requestedGainBytes)), String(describing: StorageBytes.text(record.desiredFreeBytes))))
                Text(L10n.format("최종 여유 %@ · 순변화 %@", String(describing: StorageBytes.text(record.finalFreeBytes)), String(describing: StorageBytes.changeText(record.actualChangeBytes))))
                if let approvedAt = record.approvedAt {
                    Text(L10n.format("승인 %@ · 승인 대상 %@개", String(describing: approvedAt.formatted(date: .abbreviated, time: .standard)), String(describing: record.entries.filter(\.ready).count)))
                } else {
                    Text(L10n.text("승인되지 않은 계획입니다."))
                }
                if !record.detail.isEmpty { Text(L10n.message(record.detail)) }
                ForEach(record.entries) { entry in
                    entryDetail(entry)
                }
                Text(L10n.format("계획 ID %@", String(describing: record.id.uuidString)))
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                Text(L10n.format("최종 기록 %@ · 다시 실행하려면 목표 화면에서 새로 측정하고 승인하세요.", String(describing: record.updatedAt.formatted(date: .abbreviated, time: .standard))))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.format("추가 %@ · %@", String(describing: StorageBytes.text(record.requestedGainBytes)), String(describing: record.goalMet ? L10n.text("목표 달성") : record.phase.title)))
                    .font(.body.weight(.medium))
                Text(L10n.format("%@ · %@/%@개 결과 기록", String(describing: record.createdAt.formatted(date: .abbreviated, time: .shortened)), String(describing: record.items.count), String(describing: record.entries.filter(\.ready).count)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func entryDetail(_ entry: RecoveryHistory.Entry) -> some View {
        let item = record.items.first { $0.id == entry.id }
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(entry.label) · \(item?.status ?? (record.activeEntryID == entry.id ? L10n.text("실행 결과 미확인") : (entry.ready ? L10n.text("실행 기록 없음") : entry.previewStatus)))")
                .fontWeight(.medium)
            Text(L10n.format("미리보기 점유 %@", String(describing: StorageBytes.text(entry.estimatedBytes))))
            ForEach(Array(entry.targets.enumerated()), id: \.offset) { _, path in
                Text(path).textSelection(.enabled)
            }
            if let item {
                Text(L10n.format("대상 감소 %@ · 볼륨 순변화 %@", String(describing: StorageBytes.text(item.reclaimedBytes)), String(describing: StorageBytes.changeText(item.physicalDeltaBytes))))
                if !item.detail.isEmpty { Text(L10n.message(item.detail)) }
                if !item.receipt.isEmpty { Text(L10n.format("영수증 %@", String(describing: item.receipt))).textSelection(.enabled) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
