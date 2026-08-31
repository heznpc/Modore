import SwiftUI

struct StorageWatchSignalRow: View {
    let signal: StorageWatchSignalSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            NativeStatusGlyph(symbol: symbol, tint: .secondary)
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
        switch signal.kind {
        case .swap: signal.reference
        case .processRSS: "PID \(signal.pid) · 짧은 실행명만 기록"
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
