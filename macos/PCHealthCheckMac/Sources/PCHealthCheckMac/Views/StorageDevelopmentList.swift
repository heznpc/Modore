import SwiftUI

struct DevelopmentWorkspaceList: View {
    let storage: StorageSnapshot

    var body: some View {
        List {
            if !storage.runtimeSignals.isEmpty {
                DevelopmentRuntimeSection(storage: storage)
            }
            DevelopmentAssetsSection(storage: storage)
        }
        .listStyle(.inset)
        .accessibilityLabel("개발 환경 항목")
    }

}

private struct DevelopmentRuntimeSection: View {
    let storage: StorageSnapshot

    var body: some View {
        Section {
            ForEach(storage.runtimeSignals) { signal in
                WorkspaceRuntimeRow(signal: signal)
            }
        } header: {
            NativeSectionHeader(
                title: "현재 실행 신호",
                subtitle: "정리 뒤 공간을 다시 채울 수 있는 작업입니다.",
                value: "\(storage.runtimeSignals.count)종"
            )
        }
    }
}

private struct DevelopmentAssetsSection: View {
    let storage: StorageSnapshot

    var body: some View {
        Section {
            ForEach(storage.developerToolchains) { item in
                DevelopmentAssetRow(item: item)
            }
        } header: {
            NativeSectionHeader(
                title: "설치된 개발 자산",
                subtitle: "프로젝트 요구 버전을 확인하기 전에는 삭제하지 않습니다.",
                value: storage.developerText
            )
        }
    }
}

private struct DevelopmentAssetRow: View {
    @EnvironmentObject private var model: ScanModel
    let item: StorageItem

    var body: some View {
        WorkspaceStorageItemRow(
            item: item,
            fallbackSymbol: developmentSymbol,
            status: item.measureStatus == "timed_out" ? nil : "자동 정리 안 함",
            actionTitle: item.measureStatus == "timed_out" ? "다시 측정" : nil
        ) {
            model.runScan()
        }
        .contextMenu { StorageItemContextMenu(item: item) }
    }

    private var developmentSymbol: String {
        if item.measureStatus == "timed_out" { return "hourglass" }
        let value = (item.kind + " " + item.label).lowercased()
        if value.contains("android") { return "shippingbox" }
        if value.contains("simulator") || value.contains("xcode") { return "hammer" }
        return "wrench.and.screwdriver"
    }
}

private struct WorkspaceRuntimeRow: View {
    let signal: RuntimeSignal

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: signal.risk == "warning" ? "play.circle" : "info.circle")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(signal.label)
                    .font(.body.weight(.medium))
                Text(signal.note.isEmpty ? signal.action : signal.note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(signal.countText)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 72, alignment: .trailing)
            Text(signal.risk == "warning" ? "실행 중" : "확인됨")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 116, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }
}
