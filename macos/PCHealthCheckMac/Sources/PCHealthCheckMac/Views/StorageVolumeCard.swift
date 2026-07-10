import SwiftUI

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
        let displaySegments = segments
        VStack(alignment: .leading, spacing: 16) {
            StorageVolumeHeader(
                storage: storage,
                snapshotAgeText: snapshotAgeText,
                isSnapshotStale: isSnapshotStale
            )
            StorageUsageBar(segments: displaySegments, totalGB: storage.totalGB, freeGB: storage.freeGB)
            StorageUsageLegend(segments: displaySegments)
            Divider()
            StorageChangeFooter(
                freeGB: storage.freeGB,
                text: changeText,
                symbol: changeSymbol,
                color: changeColor
            )
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
            DiskUsageSegment(id: "cleanup", label: "정리 후보", value: cleanup, color: .red.opacity(0.72)),
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

struct StorageVolumeHeader: View {
    let storage: StorageSnapshot
    let snapshotAgeText: String
    let isSnapshotStale: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Macintosh HD").font(.headline)
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
    }
}

struct StorageUsageBar: View {
    let segments: [DiskUsageSegment]
    let totalGB: Double
    let freeGB: Double

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(segments) { segment in
                    let fraction = CGFloat(segment.value / max(totalGB, 1))
                    let width = max(0, proxy.size.width * fraction)
                    ZStack {
                        segment.color
                        if segment.id == "free", width >= 66 {
                            Text("\(freeGB, specifier: "%.1f")GB")
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
    }
}

struct StorageUsageLegend: View {
    let segments: [DiskUsageSegment]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 116), spacing: 10)],
            alignment: .leading,
            spacing: 7
        ) {
            ForEach(segments.filter { $0.value >= 0.1 }) { segment in
                HStack(spacing: 6) {
                    Circle().fill(segment.color).frame(width: 8, height: 8)
                    Text(segment.label).font(.caption).foregroundStyle(.secondary)
                    Text("\(segment.value, specifier: "%.1f")GB")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
            }
        }
    }
}

struct StorageChangeFooter: View {
    let freeGB: Double
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.callout)
            Spacer()
            Text("\(freeGB, specifier: "%.1f")GB 사용 가능")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
        }
    }
}
