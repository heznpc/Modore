import AppKit
import SwiftUI

struct SettingsStorageOverviewPage: View {
    @EnvironmentObject private var model: ScanModel
    let onNavigate: (AppDestination) -> Void

    var body: some View {
        Group {
            if let storage = model.storage {
                Form {
                    Section {
                        TimelineView(.periodic(from: .now, by: 60)) { _ in
                            StorageVolumeSettingsCard(
                                storage: storage,
                                change: model.storageChange,
                                snapshotAgeText: model.storageSnapshotAgeText,
                                isSnapshotStale: model.storageSnapshotIsStale
                            )
                        }
                    }
                    StorageRecommendationsSection(
                        storage: storage,
                        change: model.storageChange,
                        onNavigate: onNavigate
                    )
                    StorageChangesSection(storage: storage, change: model.storageChange)
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: 980)
                .padding(.horizontal, 20)
            } else {
                ModernEmptyState(
                    symbol: "internaldrive",
                    title: "저장공간 정보가 없습니다",
                    message: "툴바의 새로고침 버튼으로 검사를 실행하세요."
                )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct StorageRecommendationsSection: View {
    let storage: StorageSnapshot
    let change: StorageChangeSummary?
    let onNavigate: (AppDestination) -> Void

    var body: some View {
        Section("권장") {
            leadingRecommendation
            NativeSettingsNavigationRow(
                icon: "trash",
                tint: .red,
                title: "정리 후보",
                subtitle: "캐시와 임시 파일의 논리 크기",
                value: storage.reclaimableText
            ) {
                onNavigate(.cleanup)
            }
            NativeSettingsNavigationRow(
                icon: "hammer",
                tint: .gray,
                title: "개발자",
                subtitle: "SDK, runtime 및 toolchain",
                value: storage.developerText
            ) {
                onNavigate(.development)
            }
            NativeSettingsNavigationRow(
                icon: "square.grid.2x2",
                tint: .gray,
                title: "응용 프로그램 및 Simulator",
                subtitle: "설치 앱과 가상 기기",
                value: storage.inventoryText
            ) {
                onNavigate(.inventory)
            }
        }
    }

    @ViewBuilder
    private var leadingRecommendation: some View {
        if let largest = change?.largestChanges.first {
            NativeSettingsNavigationRow(
                icon: largest.deltaGB > 0 ? "arrow.up.right" : "arrow.down.right",
                tint: largest.deltaGB > 0 ? .orange : .green,
                title: largest.label,
                subtitle: changeSubtitle(largest),
                value: String(format: "%+.1fGB", largest.deltaGB)
            ) {
                onNavigate(largest.category == "developer" ? .development : .cleanup)
            }
        } else if let largest = storage.cleanupCandidates.first {
            NativeSettingsNavigationRow(
                icon: "questionmark.folder",
                tint: .orange,
                title: largest.label,
                subtitle: "첫 비교 전 현재 큰 항목",
                value: largest.sizeText
            ) {
                onNavigate(.cleanup)
            }
        }
    }

    private func changeSubtitle(_ item: StorageItemChange) -> String {
        let verb = item.deltaGB > 0 ? "증가" : "감소"
        return String(format: "%.1fGB에서 %.1fGB로 %@", item.beforeGB, item.afterGB, verb)
    }
}

struct StorageChangesSection: View {
    let storage: StorageSnapshot
    let change: StorageChangeSummary?

    var body: some View {
        Section(change == nil ? "현재 큰 항목" : "최근 변화") {
            if let change {
                StorageChangeRows(change: change)
            } else {
                ForEach(Array(storage.cleanupCandidates.prefix(6))) { item in
                    NativeCurrentSizeRow(item: item)
                }
            }
        }
    }
}

struct StorageChangeRows: View {
    let change: StorageChangeSummary

    var body: some View {
        Group {
            if change.largestChanges.isEmpty {
                NativeSettingsMessageRow(
                    icon: "equal.circle",
                    tint: .green,
                    title: "추적 경로 변화 없음",
                    subtitle: "직전 검사와 같은 경로의 크기가 유지됐습니다."
                )
            } else {
                ForEach(Array(change.largestChanges.prefix(7))) { item in
                    NativeSettingsChangeRow(item: item)
                }
            }

            if change.unattributedConsumedGB >= 0.1 {
                NativeSettingsMessageRow(
                    icon: "questionmark.circle",
                    tint: .orange,
                    title: "추적되지 않은 사용",
                    subtitle: String(
                        format: "%.1fGB · APFS snapshot, swap 또는 제한 영역",
                        change.unattributedConsumedGB
                    )
                )
            } else if change.unattributedRecoveredGB >= 0.1 {
                NativeSettingsMessageRow(
                    icon: "arrow.up.circle",
                    tint: .green,
                    title: "추적 경로 밖에서 회복",
                    subtitle: String(
                        format: "%.1fGB · 임시 파일 또는 시스템 관리 영역",
                        change.unattributedRecoveredGB
                    )
                )
            }

            if logicalAndPhysicalSizesDiverge {
                NativeSettingsMessageRow(
                    icon: "square.2.layers.3d",
                    tint: .blue,
                    title: "논리 크기와 실제 여유 공간이 다름",
                    subtitle: "APFS clone의 공유 블록은 경로 크기를 그대로 합산할 수 없습니다."
                )
            }
        }
    }

    private var logicalAndPhysicalSizesDiverge: Bool {
        (change.freeDeltaGB > 0 && change.trackedNetDeltaGB > 0.1)
            || (change.freeDeltaGB < 0 && change.trackedNetDeltaGB < -0.1)
    }
}
