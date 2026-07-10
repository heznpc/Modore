import AppKit
import SwiftUI

struct ActivityPage: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        Form {
            Section {
                HStack {
                    Toggle(
                        "매시간 확인",
                        isOn: Binding(
                            get: { model.storageWatchEnabled },
                            set: { model.setStorageWatchEnabled($0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .disabled(model.storageWatchInFlight || model.isRunning || model.cleanupInFlight)
                    Spacer()
                    Text(model.storageWatchDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

            if !model.storageHistory.isEmpty {
                Section {
                    ForEach(Array(model.storageHistory.suffix(12).reversed())) { entry in
                        RecentScanHistoryRow(
                            entry: entry,
                            previous: model.storageHistory.last(where: { $0.capturedAt < entry.capturedAt })
                        )
                    }
                } header: {
                    NativeSectionHeader(
                        title: "검사 이력",
                        subtitle: "검사 시점의 여유 공간과 가장 큰 경로 변화를 비교합니다.",
                        value: "\(model.storageHistory.count)회"
                    )
                }
            }

            Section {
                ScrollView {
                    Text(model.logText.isEmpty ? "아직 실행 로그가 없습니다." : model.logText)
                        .font(.caption.monospaced())
                        .foregroundStyle(model.logText.isEmpty ? .secondary : .primary)
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
                    Button("로그 지우기", systemImage: "trash") {
                        model.clearLog()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.logText.isEmpty)
                    .textCase(nil)
                }
            }
        }
        .macSettingsFormStyle()
    }
}
struct RecentScanHistoryRow: View {
    let entry: StorageHistoryEntry
    let previous: StorageHistoryEntry?

    var body: some View {
        HStack(spacing: 12) {
            NativeStatusGlyph(symbol: changeSymbol, tint: changeTint)
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
            parts.append(String(format: "%@ 논리 %+.1fGB", largest.label, largest.deltaGB))
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

    private var changeTint: Color {
        guard let change else { return .secondary }
        if change.freeDeltaGB < -0.05 { return .orange }
        if change.freeDeltaGB > 0.05 { return .green }
        return .secondary
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

            GeometryReader { proxy in
                let values = samples.map(\.freeGB)
                let minimum = values.min() ?? 0
                let maximum = values.max() ?? 1
                let span = max(maximum - minimum, 0.5)
                Path { path in
                    for (index, value) in values.enumerated() {
                        let x = values.count <= 1
                            ? 0
                            : proxy.size.width * CGFloat(index) / CGFloat(values.count - 1)
                        let y = proxy.size.height * CGFloat(1 - (value - minimum) / span)
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
