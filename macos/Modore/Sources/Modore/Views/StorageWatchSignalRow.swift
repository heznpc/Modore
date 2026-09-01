import SwiftUI

struct StorageWatchSignalRow: View {
    let signal: StorageWatchSignalSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            NativeStatusGlyph(
                symbol: signal.isComplete ? symbol : "clock",
                tint: .secondary
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(signal.label)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(detail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(measurement)
                .font(.callout.weight(.semibold))
                .foregroundStyle(signal.isComplete ? .primary : .secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
    }

    private var symbol: String {
        switch signal.kind {
        case .swap: "internaldrive"
        case .processRSS: "memorychip"
        }
    }

    private var detail: String {
        let capturedDetail = switch signal.kind {
        case .swap: signal.reference
        case .processRSS: "PID \(signal.pid) · 짧은 실행명만 기록"
        }
        guard signal.isPartial else { return capturedDetail }
        return "\(capturedDetail) · \(partialStatusText)"
    }

    private var partialStatusText: String {
        switch signal.status {
        case .ok: "측정 완료"
        case .timedOut: "시간 제한 전 일부 수집"
        case .outputLimited: "출력 제한 전 일부 수집"
        case .failed: "중단 전 일부 수집"
        }
    }

    private var measurement: String {
        switch signal.kind {
        case .swap:
            return String(
                format: "%.1f/%.1fGB",
                signal.valueKB / 1_048_576,
                signal.allocatedKB / 1_048_576
            )
        case .processRSS:
            return String(format: "%.0fMB RAM", signal.valueKB / 1_024)
        }
    }
}

extension StorageWatchSignalEvent {
    func collectionSummary(for kind: StorageWatchSignalKind, label: String) -> String {
        let matching = rows.filter { $0.kind == kind }
        guard !matching.isEmpty else { return "\(label) 신호 없음" }
        guard matching.allSatisfy(\.isComplete) else {
            if matching.contains(where: { $0.status == .timedOut }) {
                return "\(label) 시간 제한으로 일부만 수집"
            }
            if matching.contains(where: { $0.status == .outputLimited }) {
                return "\(label) 출력 제한으로 일부만 수집"
            }
            return "\(label) 중단 전에 일부만 수집"
        }
        return "\(label) 측정 완료"
    }
}
