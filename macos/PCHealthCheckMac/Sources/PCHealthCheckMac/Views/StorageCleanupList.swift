import SwiftUI

struct CleanupWorkspaceList: View {
    let storage: StorageSnapshot

    var body: some View {
        List {
            CleanupCandidateSection(storage: storage)
            if !storage.reviewCandidates.isEmpty {
                CleanupProtectedSection(storage: storage)
            }
        }
        .listStyle(.inset)
        .accessibilityLabel("저장공간 정리 항목")
    }
}

private struct CleanupCandidateSection: View {
    let storage: StorageSnapshot

    var body: some View {
        Section {
            ForEach(executableCandidates) { item in
                CleanupCandidateRow(item: item)
            }
        } header: {
            NativeSectionHeader(
                title: "정리 미리보기 가능",
                subtitle: "합계는 실행 가능한 대상의 점유 추정이며, 실행 직전에 다시 측정합니다.",
                value: storage.reclaimableText
            )
        }

        if !manualCandidates.isEmpty {
            Section {
                ForEach(manualCandidates) { item in
                    CleanupCandidateRow(item: item)
                }
            } header: {
                NativeSectionHeader(
                    title: "수동 확인",
                    subtitle: "실행 recipe가 없는 넓은 경로입니다. Finder에서 개별 항목을 검토하세요.",
                    value: "\(manualCandidates.count)개"
                )
            }
        }
    }

    private var executableCandidates: [StorageItem] {
        storage.cleanupCandidates.filter(\.hasSupportedCleanupRecipe)
    }

    private var manualCandidates: [StorageItem] {
        storage.cleanupCandidates.filter { !$0.hasSupportedCleanupRecipe }
    }
}

private struct CleanupCandidateRow: View {
    @EnvironmentObject private var model: ScanModel
    let item: StorageItem

    var body: some View {
        WorkspaceStorageItemRow(
            item: item,
            fallbackSymbol: cleanupSymbol,
            status: item.canCleanup || canRetryMeasurement ? nil : "수동 확인",
            actionTitle: actionTitle
        ) {
            if item.measureStatus == "timed_out" {
                model.runScan()
            } else {
                model.prepareCleanup(item)
            }
        }
        .contextMenu { StorageItemContextMenu(item: item) }
    }

    private var actionTitle: String? {
        if canRetryMeasurement { return "다시 측정" }
        return item.canCleanup ? "정리 검토…" : nil
    }

    private var canRetryMeasurement: Bool {
        item.measureStatus == "timed_out" && item.hasSupportedCleanupRecipe
    }

    private var cleanupSymbol: String {
        if item.measureStatus == "timed_out" { return "hourglass" }
        if item.label.localizedCaseInsensitiveContains("Playwright") {
            return "rectangle.stack.badge.play"
        }
        if item.label.localizedCaseInsensitiveContains("cache") {
            return "folder.badge.gearshape"
        }
        return "arrow.triangle.2.circlepath"
    }
}

private struct CleanupProtectedSection: View {
    let storage: StorageSnapshot

    var body: some View {
        Section {
            ForEach(storage.reviewCandidates) { item in
                WorkspaceStorageItemRow(
                    item: item,
                    fallbackSymbol: "lock.shield",
                    status: "보호됨"
                )
                .contextMenu { StorageItemContextMenu(item: item) }
            }
        } header: {
            NativeSectionHeader(
                title: "보호 및 확인",
                subtitle: "Codex·Claude 세션, 작업 기록과 내부 DB는 자동 정리하지 않습니다.",
                value: storage.reviewText
            )
        }
    }
}

struct StorageItemContextMenu: View {
    @EnvironmentObject private var model: ScanModel
    let item: StorageItem

    var body: some View {
        Button { model.revealStorageItem(item) } label: {
            Label("Finder에서 보기", systemImage: "folder")
        }
        Button { model.copyGuide(for: item) } label: {
            Label("정보 복사", systemImage: "doc.on.clipboard")
        }
    }
}
