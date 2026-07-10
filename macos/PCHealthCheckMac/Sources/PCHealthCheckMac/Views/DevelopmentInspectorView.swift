import AppKit
import SwiftUI

struct DevelopmentInspectorPane: View {
    @EnvironmentObject private var model: ScanModel
    let record: DevelopmentRecord

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                inspectorContent
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            actionBar
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor))
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var inspectorContent: some View {
        switch record {
        case .runtime(let signal):
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 12) {
                    NativeStatusGlyph(symbol: runtimeSymbol(signal), tint: runtimeTint(signal))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(signal.label)
                            .font(.title3.weight(.semibold))
                        Text(signal.countText)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                Label(runtimeStatus(signal), systemImage: runtimeStatusSymbol(signal))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(runtimeTint(signal))

                Divider()

                InspectorTextSection(title: "의미") {
                    Text(signal.note.isEmpty ? "현재 실행 상태를 확인한 결과입니다." : signal.note)
                }

                InspectorTextSection(title: "권장 조치") {
                    Text(signal.action)
                }

                Text("실행원을 종료해도 관련 도구를 다시 사용하면 공간이 재생성될 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .asset(let item):
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 12) {
                    NativeSourceIcon(item: item, fallbackSymbol: assetSymbol(item))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.label)
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 5) {
                            Text(item.sizeText)
                                .font(.body.weight(.medium))
                                .monospacedDigit()
                            Text("· \(model.storageSnapshotAgeText)")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                }

                Label(
                    item.measureStatus == "timed_out" ? "크기 측정이 보류되었습니다" : "자동 정리에서 제외된 개발 자산입니다",
                    systemImage: item.measureStatus == "timed_out" ? "hourglass" : "lock.shield"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(item.measureStatus == "timed_out" ? .orange : .secondary)

                Divider()

                InspectorTextSection(title: "판단") {
                    Text(item.note.isEmpty ? item.action : item.note)
                }

                if !item.action.isEmpty && item.action != item.note {
                    InspectorTextSection(title: "권장 조치") {
                        Text(item.action)
                    }
                }

                InspectorTextSection(title: "경로") {
                    Text(item.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        switch record {
        case .runtime:
            HStack {
                Spacer()
                Button {
                    model.runScan()
                } label: {
                    Label("다시 검사", systemImage: "arrow.clockwise")
                        .frame(minWidth: 150)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isBusy)
            }

        case .asset(let item):
            VStack(alignment: .trailing, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        assetFinderButton(item)
                        assetCopyButton(item)
                    }
                    VStack(alignment: .trailing, spacing: 8) {
                        assetFinderButton(item)
                        assetCopyButton(item)
                    }
                }

                if item.measureStatus == "timed_out" {
                    Button {
                        model.runScan()
                    } label: {
                        Label("다시 측정", systemImage: "arrow.clockwise")
                            .frame(minWidth: 150)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isBusy)
                }
            }
        }
    }

    private func assetFinderButton(_ item: StorageItem) -> some View {
        Button {
            model.revealStorageItem(item)
        } label: {
            Label("Finder에서 보기", systemImage: "folder")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .fixedSize()
    }

    private func assetCopyButton(_ item: StorageItem) -> some View {
        Button {
            model.copyGuide(for: item)
        } label: {
            Label("정보 복사", systemImage: "doc.on.clipboard")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .fixedSize()
    }

    private func runtimeSymbol(_ signal: RuntimeSignal) -> String {
        switch signal.risk {
        case "warning": return "exclamationmark"
        case "safe": return "checkmark"
        default: return "info.circle"
        }
    }

    private func runtimeStatusSymbol(_ signal: RuntimeSignal) -> String {
        signal.risk == "warning" ? "exclamationmark.triangle" : "info.circle"
    }

    private func runtimeStatus(_ signal: RuntimeSignal) -> String {
        if signal.risk == "warning" {
            return "현재 공간을 다시 채울 수 있는 실행 신호입니다"
        }
        if signal.risk == "safe" {
            return "현재 특별한 실행 경고가 없습니다"
        }
        return "현재 실행 상태를 확인했습니다"
    }

    private func runtimeTint(_ signal: RuntimeSignal) -> Color {
        signal.risk == "warning" ? .orange : .secondary
    }

    private func assetSymbol(_ item: StorageItem) -> String {
        if item.measureStatus == "timed_out" { return "hourglass" }
        let value = (item.kind + " " + item.label).lowercased()
        if value.contains("android") { return "shippingbox" }
        if value.contains("simulator") || value.contains("xcode") { return "hammer" }
        return "wrench.and.screwdriver"
    }
}
