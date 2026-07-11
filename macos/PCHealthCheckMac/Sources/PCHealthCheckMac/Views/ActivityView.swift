import SwiftUI

struct ActivityPage: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        Form {
            StorageWatchActivitySection()

            if !model.storageHistory.isEmpty {
                ScanHistorySection(entries: model.storageHistory)
            }

            ScanLogSection(store: model.logStore, clearAction: model.clearLog)
        }
        .macSettingsFormStyle()
    }
}

private struct StorageWatchActivitySection: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: model.storageWatchEnabled ? "checkmark.circle" : "pause.circle")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.storageWatchEnabled ? "급감 감시 켜짐" : "급감 감시 꺼짐")
                        .font(.body.weight(.medium))
                    Text(model.storageWatchDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StorageWatchSettingsButton()
            }
            if !model.freeSpaceSamples.isEmpty {
                FreeSpaceTrendView(samples: Array(model.freeSpaceSamples.suffix(48)))
                    .frame(height: 120)
            } else {
                Text("시간별 표본이 아직 없습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            NativeSectionHeader(
                title: "저장공간 변화",
                subtitle: "여유 공간만 기록하며 파일을 삭제하지 않습니다.",
                value: "\(model.freeSpaceSamples.count)개 표본"
            )
        }
    }
}

private struct ScanHistorySection: View {
    let entries: [StorageHistoryEntry]

    var body: some View {
        Section {
            ForEach(Array(entries.suffix(12).reversed())) { entry in
                RecentScanHistoryRow(
                    entry: entry,
                    previous: entries.last(where: { $0.capturedAt < entry.capturedAt })
                )
            }
        } header: {
            NativeSectionHeader(
                title: "검사 이력",
                subtitle: "검사 시점의 여유 공간과 가장 큰 경로 변화를 비교합니다.",
                value: "\(entries.count)회"
            )
        }
    }
}

private struct StorageWatchSettingsButton: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                Label("감시 설정…", systemImage: "gear")
            }
            .buttonStyle(.bordered)
        } else {
            Text("⌘, 에서 설정")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct ScanLogSection: View {
    @ObservedObject var store: ScanLogStore
    let clearAction: () -> Void

    var body: some View {
        Section {
            ScrollView {
                Text(store.isEmpty ? "아직 실행 로그가 없습니다." : store.text)
                    .font(.caption.monospaced())
                    .foregroundStyle(store.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 200, maxHeight: 320)
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        } header: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("실행 로그")
                    Text("검사와 승인형 정리의 로컬 출력입니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
                Spacer()
                Button("로그 지우기", systemImage: "trash", action: clearAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.isEmpty)
                    .textCase(nil)
            }
        }
    }
}

struct RecentScanHistoryRow: View {
    let entry: StorageHistoryEntry
    let previous: StorageHistoryEntry?

    var body: some View {
        HStack(spacing: 12) {
            NativeStatusGlyph(symbol: changeSymbol, tint: .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.body.weight(.medium))
                Text(changeDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(entry.freeGB, specifier: "%.1f")GB")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                Text("사용 가능")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var change: StorageChangeSummary? {
        guard let previous else { return nil }
        return StorageChangeSummary(entries: [previous, entry])
    }

    private var changeDescription: String {
        guard let change else { return "첫 비교 기준점" }
        var parts = [String(format: "사용 가능 %+.1fGB", change.freeDeltaGB)]
        if change.unattributedConsumedGB >= 0.1 {
            parts.append(String(format: "추적 밖 사용 %.1fGB", change.unattributedConsumedGB))
        } else if change.unattributedRecoveredGB >= 0.1 {
            parts.append(String(format: "추적 밖 회복 %.1fGB", change.unattributedRecoveredGB))
        }
        if let largest = change.largestChanges.first {
            parts.append(String(format: "%@ 경로 점유 %+.1fGB", largest.label, largest.deltaGB))
            return parts.joined(separator: " · ")
        }
        if abs(change.freeDeltaGB) >= 0.05 {
            parts.append("추적 경로 변화 없음")
            return parts.joined(separator: " · ")
        }
        return "추적 경로와 여유 공간 변화 없음"
    }

    private var changeSymbol: String {
        guard let change else { return "record.circle" }
        if change.freeDeltaGB < -0.05 { return "arrow.down.right" }
        if change.freeDeltaGB > 0.05 { return "arrow.up.right" }
        return "equal.circle"
    }

}

struct FreeSpaceTrendView: View {
    let samples: [FreeSpaceSample]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let first = samples.first, let last = samples.last {
                    Text("\(first.freeGB, specifier: "%.1f")GB")
                    Image(systemName: "arrow.right")
                    Text("\(last.freeGB, specifier: "%.1f")GB")
                        .fontWeight(.semibold)
                }
                Spacer()
                Text("최근 \(samples.count)회")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            FreeSpaceSparkline(values: samples.map(\.freeGB))
        }
    }
}

struct FreeSpaceSparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { proxy in
            makePath(in: proxy.size)
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("여유 공간 추세 그래프")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard let first = values.first, let last = values.last else {
            return "표본 없음"
        }
        let minimum = values.min() ?? last
        let maximum = values.max() ?? last
        return String(
            format: "최근 %d회, 처음 %.1fGB, 현재 %.1fGB, 최저 %.1fGB, 최고 %.1fGB",
            values.count,
            first,
            last,
            minimum,
            maximum
        )
    }

    private func makePath(in size: CGSize) -> Path {
        let points = chartPoints(in: size)
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    private func chartPoints(in size: CGSize) -> [CGPoint] {
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? 1
        let span = max(maximum - minimum, 0.5)
        let horizontalStep = values.count <= 1
            ? 0
            : size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let x = horizontalStep * CGFloat(index)
            let normalizedValue = CGFloat((value - minimum) / span)
            return CGPoint(x: x, y: size.height * (1 - normalizedValue))
        }
    }
}
