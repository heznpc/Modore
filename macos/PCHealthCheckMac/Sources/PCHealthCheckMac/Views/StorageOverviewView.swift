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

                    Section("권장") {
                        if let change = model.storageChange,
                           let largest = change.largestChanges.first {
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

                    Section(model.storageChange == nil ? "현재 큰 항목" : "최근 변화") {
                        if let change = model.storageChange {
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
                            if (change.freeDeltaGB > 0 && change.trackedNetDeltaGB > 0.1)
                                || (change.freeDeltaGB < 0 && change.trackedNetDeltaGB < -0.1) {
                                NativeSettingsMessageRow(
                                    icon: "square.2.layers.3d",
                                    tint: .blue,
                                    title: "논리 크기와 실제 여유 공간이 다름",
                                    subtitle: "APFS clone의 공유 블록은 경로 크기를 그대로 합산할 수 없습니다."
                                )
                            }
                        } else {
                            ForEach(Array(storage.cleanupCandidates.prefix(6))) { item in
                                NativeCurrentSizeRow(item: item)
                            }
                        }
                    }
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

    private func changeSubtitle(_ item: StorageItemChange) -> String {
        let verb = item.deltaGB > 0 ? "증가" : "감소"
        return String(format: "%.1fGB에서 %.1fGB로 %@", item.beforeGB, item.afterGB, verb)
    }
}
struct DiskUsageSegment: Identifiable {
    let id: String
    let label: String
    let value: Double
    let color: Color
}

struct StorageVolumeSettingsCard: View {
    let storage: StorageSnapshot
    let change: StorageChangeSummary?
    let snapshotAgeText: String
    let isSnapshotStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Macintosh HD")
                    .font(.headline)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(storage.totalGB, specifier: "%.1f")GB 중 \(storage.usedGB, specifier: "%.1f")GB 사용됨")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text(snapshotAgeText)
                        .font(.caption)
                        .foregroundStyle(isSnapshotStale ? Color.orange : Color.secondary)
                }
            }

            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach(segments) { segment in
                        let width = max(0, proxy.size.width * segment.value / max(storage.totalGB, 1))
                        ZStack {
                            segment.color
                            if segment.id == "free", width >= 66 {
                                Text("\(storage.freeGB, specifier: "%.1f")GB")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .frame(width: width)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .frame(height: 30)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 10)], alignment: .leading, spacing: 7) {
                ForEach(segments.filter { $0.value >= 0.1 }) { segment in
                    HStack(spacing: 6) {
                        Circle().fill(segment.color).frame(width: 8, height: 8)
                        Text(segment.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(segment.value, specifier: "%.1f")GB")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                Image(systemName: changeSymbol)
                    .foregroundStyle(changeColor)
                Text(changeText)
                    .font(.callout)
                Spacer()
                Text("\(storage.freeGB, specifier: "%.1f")GB 사용 가능")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 6)
    }

    private var segments: [DiskUsageSegment] {
        let cleanup = min(storage.reclaimableGB, storage.usedGB)
        let review = min(storage.reviewGB, max(0, storage.usedGB - cleanup))
        let developer = min(storage.developerGB, max(0, storage.usedGB - cleanup - review))
        let apps = min(storage.inventoryGB, max(0, storage.usedGB - cleanup - review - developer))
        let other = max(0, storage.usedGB - cleanup - review - developer - apps)
        let reserved = max(0, storage.totalGB - storage.usedGB - storage.freeGB)
        return [
            DiskUsageSegment(id: "cleanup", label: "정리 후보", value: cleanup, color: Color(nsColor: .systemRed).opacity(0.72)),
            DiskUsageSegment(id: "review", label: "보호 데이터", value: review, color: .primary.opacity(0.55)),
            DiskUsageSegment(id: "developer", label: "개발자", value: developer, color: .primary.opacity(0.46)),
            DiskUsageSegment(id: "apps", label: "앱 및 Simulator", value: apps, color: .primary.opacity(0.38)),
            DiskUsageSegment(id: "other", label: "기타", value: other, color: .primary.opacity(0.30)),
            DiskUsageSegment(id: "reserved", label: "macOS 및 예약", value: reserved, color: .primary.opacity(0.22)),
            DiskUsageSegment(id: "free", label: "사용 가능", value: storage.freeGB, color: .primary.opacity(0.12))
        ]
    }

    private var changeText: String {
        guard let change else { return "비교 기록이 시작되었습니다." }
        if change.consumedGB >= 0.05 {
            return String(format: "직전 검사 이후 사용 가능 공간이 %.1fGB 줄었습니다.", change.consumedGB)
        }
        if change.recoveredGB >= 0.05 {
            return String(format: "직전 검사 이후 사용 가능 공간이 %.1fGB 늘었습니다.", change.recoveredGB)
        }
        return "직전 검사 이후 사용 가능 공간 변화가 거의 없습니다."
    }

    private var changeSymbol: String {
        guard let change else { return "record.circle" }
        if change.consumedGB >= 0.05 { return "arrow.down.right" }
        if change.recoveredGB >= 0.05 { return "arrow.up.right" }
        return "equal.circle"
    }

    private var changeColor: Color {
        guard let change else { return .blue }
        if change.consumedGB >= 0.05 { return .red }
        if change.recoveredGB >= 0.05 { return .green }
        return .secondary
    }
}

struct SettingsGroupTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .padding(.leading, 2)
    }
}

struct SettingsCardGroup<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 14)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SettingsIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: max(6, size * 0.22)))
    }
}

struct SettingsRecommendationRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let value: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SettingsIcon(symbol: icon, tint: tint, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Divider().padding(.leading, 46)
    }
}

struct SettingsChangeListRow: View {
    let item: StorageItemChange

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(
                symbol: item.deltaGB > 0 ? "arrow.up" : "arrow.down",
                tint: item.deltaGB > 0 ? .orange : .green,
                size: 30
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(.body.weight(.medium))
                Text("\(item.beforeGB, specifier: "%.1f") → \(item.afterGB, specifier: "%.1f")GB · 논리 크기")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(format: "%+.1fGB", item.deltaGB))
                .foregroundStyle(item.deltaGB > 0 ? .orange : .green)
                .monospacedDigit()
        }
        .padding(.vertical, 10)
        Divider().padding(.leading, 42)
    }
}

struct SettingsCurrentSizeRow: View {
    let item: StorageItem

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: "folder", tint: .orange, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label).font(.body.weight(.medium))
                Text(item.action).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(item.sizeText).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 10)
        Divider().padding(.leading, 42)
    }
}

struct SettingsMessageRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsIcon(symbol: icon, tint: tint, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 10)
        Divider().padding(.leading, 42)
    }
}

struct NativeStatusGlyph: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct NativeSettingsNavigationRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let value: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SettingsIcon(symbol: icon, tint: tint, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 14)
                Text(value)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

struct NativeSettingsChangeRow: View {
    let item: StorageItemChange

    var body: some View {
        HStack(spacing: 12) {
            NativeStatusGlyph(
                symbol: item.deltaGB > 0 ? "arrow.up" : "arrow.down",
                tint: item.deltaGB > 0 ? .orange : .green
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(.body.weight(.medium))
                Text("\(item.beforeGB, specifier: "%.1f") → \(item.afterGB, specifier: "%.1f")GB · 논리 크기")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(format: "%+.1fGB", item.deltaGB))
                .font(.callout.weight(.medium))
                .foregroundStyle(item.deltaGB > 0 ? .orange : .green)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
    }
}

struct NativeCurrentSizeRow: View {
    let item: StorageItem

    var body: some View {
        HStack(spacing: 12) {
            NativeStatusGlyph(symbol: "folder", tint: .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label).font(.body.weight(.medium))
                Text(item.action).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Text(item.sizeText).font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 4)
    }
}

struct NativeSettingsMessageRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            NativeStatusGlyph(symbol: icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct NativeSectionHeader: View {
    let title: String
    let subtitle: String
    var value: String = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
            Spacer()
            if !value.isEmpty {
                Text(value)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .textCase(nil)
            }
        }
    }
}

extension View {
    func macSettingsFormStyle() -> some View {
        self
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 980)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct StorageOverviewPage: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        ScrollView {
            if let storage = model.storage {
                VStack(alignment: .leading, spacing: 28) {
                    StorageOverviewHeader(storage: storage, change: model.storageChange)
                    Divider()
                    CauseAnalysisSection(storage: storage, change: model.storageChange)
                    Divider()
                    QuickActionsSection(storage: storage)
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .top)
            } else {
                ModernEmptyState(
                    symbol: "internaldrive",
                    title: "저장공간 기준점이 없습니다",
                    message: "검사를 실행하면 현재 상태를 기록합니다."
                )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct StorageOverviewHeader: View {
    let storage: StorageSnapshot
    let change: StorageChangeSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("남은 저장공간")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(storage.freeGB, specifier: "%.1f")GB")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(storage.riskColor)
                        .monospacedDigit()
                    Text("전체 \(storage.totalGB, specifier: "%.1f")GB 중 \(Int(storage.usePercent))% 사용")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ChangeHeadline(change: change)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.16))
                    Capsule()
                        .fill(storage.riskColor)
                        .frame(width: proxy.size.width * min(max(storage.usePercent / 100, 0), 1))
                }
            }
            .frame(height: 9)
        }
    }
}

struct ChangeHeadline: View {
    let change: StorageChangeSummary?

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            if let change {
                if change.consumedGB >= 0.05 {
                    Label("\(change.consumedGB, specifier: "%.1f")GB 감소", systemImage: "arrow.down.right")
                        .foregroundStyle(.red)
                } else if change.recoveredGB >= 0.05 {
                    Label("\(change.recoveredGB, specifier: "%.1f")GB 회복", systemImage: "arrow.up.right")
                        .foregroundStyle(.green)
                } else {
                    Label("변화 거의 없음", systemImage: "equal")
                        .foregroundStyle(.secondary)
                }
                Text("직전 점검 이후")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(change.previous.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Label("비교 기록 시작", systemImage: "record.circle")
                    .foregroundStyle(.blue)
                Text("이번 검사가 첫 기준점입니다")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.title3.weight(.semibold))
    }
}

struct CauseAnalysisSection: View {
    let storage: StorageSnapshot
    let change: StorageChangeSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(
                title: "왜 변했나",
                subtitle: change == nil ? "현재 큰 항목만 표시합니다. 증가량은 다음 검사부터 비교됩니다." : "직전 점검과 같은 경로의 크기를 비교했습니다."
            )

            if let change {
                if change.largestChanges.isEmpty {
                    Text("추적 중인 경로에서는 의미 있는 크기 변화가 없습니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(change.largestChanges.prefix(6))) { item in
                        StorageChangeRow(
                            item: item,
                            direction: item.deltaGB > 0 ? .growth : .shrink
                        )
                    }
                }

                if change.unattributedConsumedGB >= 0.1 {
                    UnattributedChangeRow(sizeGB: change.unattributedConsumedGB, recovered: false)
                } else if change.unattributedRecoveredGB >= 0.1 {
                    UnattributedChangeRow(sizeGB: change.unattributedRecoveredGB, recovered: true)
                }

                if (change.freeDeltaGB > 0 && change.trackedNetDeltaGB > 0.1)
                    || (change.freeDeltaGB < 0 && change.trackedNetDeltaGB < -0.1) {
                    LogicalPhysicalNote()
                }
            } else {
                ForEach(Array(storage.cleanupCandidates.sorted { $0.sizeGB > $1.sizeGB }.prefix(4))) { item in
                    CurrentSuspectRow(item: item)
                }
            }
        }
    }
}

enum StorageChangeDirection {
    case growth
    case shrink
}

struct StorageChangeRow: View {
    let item: StorageItemChange
    let direction: StorageChangeDirection

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: direction == .growth ? "arrow.up" : "arrow.down")
                .foregroundStyle(direction == .growth ? .red : .green)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.label)
                    .font(.body.weight(.semibold))
                Text("\(categoryText) · \(item.beforeGB, specifier: "%.1f") → \(item.afterGB, specifier: "%.1f")GB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(signedText)
                .font(.body.weight(.semibold))
                .foregroundStyle(direction == .growth ? .red : .green)
                .monospacedDigit()
        }
        .padding(.vertical, 6)
    }

    private var signedText: String {
        String(format: "%+.1fGB", item.deltaGB)
    }

    private var categoryText: String {
        switch item.category {
        case "cleanup": return "재생성 가능한 항목"
        case "review": return "삭제 전 확인 항목"
        default: return "개발 환경"
        }
    }
}

struct UnattributedChangeRow: View {
    let sizeGB: Double
    let recovered: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.orange)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(recovered ? "추적 경로 밖에서 회복" : "추적 경로 밖에서 사용")
                    .font(.body.weight(.semibold))
                Text("APFS snapshot, swap, 시스템 임시 파일 또는 스캔 제한 영역이 포함될 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(sizeGB, specifier: "%.1f")GB")
                .font(.body.weight(.semibold))
                .foregroundStyle(.orange)
                .monospacedDigit()
        }
        .padding(.vertical, 6)
    }
}

struct LogicalPhysicalNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "square.2.layers.3d")
                .foregroundStyle(.blue)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text("경로 크기와 실제 여유 공간의 방향이 다릅니다")
                    .font(.body.weight(.semibold))
                Text("APFS clone의 공유 블록과 동시에 정리된 임시 파일 때문에 논리 크기를 그대로 더할 수 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

struct CurrentSuspectRow: View {
    let item: StorageItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: suspectSymbol)
                .foregroundStyle(.orange)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.label)
                    .font(.body.weight(.semibold))
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(item.sizeText)
                .font(.body.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.vertical, 6)
    }

    private var suspectSymbol: String {
        if item.label.localizedCaseInsensitiveContains("Chrome") { return "globe" }
        if item.label.localizedCaseInsensitiveContains("Playwright") { return "rectangle.on.rectangle" }
        if item.label.localizedCaseInsensitiveContains("Codex") { return "terminal" }
        return "folder"
    }

    private var reason: String {
        if item.label.localizedCaseInsensitiveContains("Chrome") {
            return "Chrome 또는 브라우저 자동화가 만드는 임시 code-sign clone"
        }
        if item.label.localizedCaseInsensitiveContains("Playwright") {
            return "브라우저 테스트가 내려받은 실행 파일"
        }
        if item.label.localizedCaseInsensitiveContains("Codex") {
            return "Codex가 다시 받을 수 있는 로컬 런타임 캐시"
        }
        return item.action
    }
}

struct QuickActionsSection: View {
    let storage: StorageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "지금 할 일", subtitle: "정리 전 대상과 실행 중인 프로세스를 다시 확인합니다.")
            ForEach(Array(storage.cleanupCandidates.prefix(5))) { item in
                ModernStorageRow(item: item, mode: .cleanup)
            }
        }
    }
}
