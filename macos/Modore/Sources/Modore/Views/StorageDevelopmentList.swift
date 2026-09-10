import SwiftUI

struct DevelopmentWorkspaceList: View {
    let storage: StorageSnapshot

    var body: some View {
        List {
            if storage.browserAutomation.verdict != "unknown" {
                BrowserAutomationSection(storage: storage)
            }
            if !generalRuntimeSignals.isEmpty {
                DevelopmentRuntimeSection(signals: generalRuntimeSignals)
            }
            DevelopmentAssetsSection(storage: storage)
        }
        .listStyle(.inset)
        .accessibilityLabel(L10n.text("개발 환경 항목"))
    }

    private var generalRuntimeSignals: [RuntimeSignal] {
        storage.runtimeSignals.filter { $0.kind != "browser_automation_root" }
    }

}

private struct DevelopmentRuntimeSection: View {
    let signals: [RuntimeSignal]

    var body: some View {
        Section {
            ForEach(signals) { signal in
                WorkspaceRuntimeRow(signal: signal)
            }
        } header: {
            NativeSectionHeader(
                title: L10n.text("현재 실행 신호"),
                subtitle: L10n.text("정리 뒤 공간을 다시 채울 수 있는 작업입니다."),
                value: L10n.format("%@종", String(describing: signals.count))
            )
        }
    }
}

private struct BrowserAutomationSection: View {
    let storage: StorageSnapshot

    var body: some View {
        Section {
            BrowserAutomationSummaryRow(status: storage.browserAutomation)
            BrowserIsolationConfigurationRow(status: storage.browserAutomation)
            ForEach(browserRoots) { signal in
                BrowserAutomationRootRow(signal: signal)
            }
        } header: {
            NativeSectionHeader(
                title: L10n.text("브라우저 자동화"),
                subtitle: L10n.text("일반 Chrome과의 충돌·메모리를 확인하며 자동 종료하지 않습니다."),
                value: summaryValue
            )
        }
    }

    private var browserRoots: [RuntimeSignal] {
        storage.runtimeSignals.filter { $0.kind == "browser_automation_root" }
    }

    private var summaryValue: String {
        switch storage.browserAutomation.verdict {
        case "orphaned": return L10n.format("잔류 %@개", String(describing: storage.browserAutomation.orphanedRootCount))
        case "conflict_possible": return L10n.text("충돌 가능")
        case "isolated_active": return L10n.text("격리 실행 중")
        default: return L10n.text("현재 신호 없음")
        }
    }
}

private struct BrowserAutomationSummaryRow: View {
    let status: BrowserAutomationStatus

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(L10n.message(status.note))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(value)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 6)
    }

    private var title: String {
        switch status.verdict {
        case "orphaned": return L10n.text("소유 작업을 찾지 못한 오래된 자동화가 있습니다")
        case "conflict_possible": return L10n.text("기본 Chrome을 사용하는 자동화가 있습니다")
        case "isolated_active": return L10n.text("격리 브라우저에서 자동화 중입니다")
        default: return L10n.text("현재 자동화 충돌 신호가 없습니다")
        }
    }

    private var symbol: String {
        switch status.verdict {
        case "orphaned": return "questionmark.circle"
        case "conflict_possible": return "rectangle.on.rectangle"
        case "isolated_active": return "checkmark.circle"
        default: return "circle.dashed"
        }
    }

    private var value: String {
        guard status.rootCount > 0 else { return L10n.text("확인됨") }
        return status.treeMemoryKB > 0
            ? L10n.format("%@개 · RSS≈%@", String(describing: status.rootCount), String(describing: status.treeMemoryText))
            : L10n.format("%@개 루트", String(describing: status.rootCount))
    }
}

private struct BrowserIsolationConfigurationRow: View {
    let status: BrowserAutomationStatus

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "gearshape")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("Playwright 전역 격리 설정"))
                    .font(.body.weight(.medium))
                Text(configurationDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(status.globalIsolationConfigured ? L10n.text("격리됨") : L10n.text("미설정"))
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private var configurationDetail: String {
        if status.globalIsolationConfigured {
            return L10n.format("%@에서 Chromium 격리를 확인했습니다.", String(describing: status.configLocation))
        }
        if status.globalConfigPresent {
            return L10n.text("설정 파일은 있지만 Chromium 격리가 강제되지 않습니다.")
        }
        return L10n.text("전역 설정 파일이 없습니다. 자동화 도구의 기본 채널 선택을 확인하세요.")
    }
}

private struct BrowserAutomationRootRow: View {
    @EnvironmentObject private var model: ScanModel
    let signal: RuntimeSignal

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isOrphanCandidate ? "questionmark.circle" : "play.circle")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.message(signal.label))
                    .font(.body.weight(.medium))
                Text(metadata)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(L10n.message(signal.action))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 6) {
                Text(statusText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if canRequestStop {
                    Button(L10n.text("종료 검토")) {
                        model.prepareBrowserAutomationStop(signal: signal)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isBusy)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var isOrphanCandidate: Bool {
        signal.state == "orphan_candidate" || signal.state == "orphaned"
    }

    private var canRequestStop: Bool {
        guard signal.pid > 1 else { return false }
        if signal.channel == "isolated" { return true }
        return signal.channel == "system"
            && signal.profile == "temporary"
    }

    private var statusText: String {
        if signal.channel == "system" && signal.profile == "default" {
            return L10n.text("기본 프로필 보호")
        }
        return isOrphanCandidate ? L10n.text("잔류 후보") : L10n.text("실행 중")
    }

    private var metadata: String {
        var parts = ["PID \(signal.pid)", L10n.format("부모 %@", String(describing: signal.parentPid))]
        if !signal.elapsed.isEmpty { parts.append(L10n.format("실행 %@", String(describing: signal.elapsed))) }
        if !signal.channel.isEmpty { parts.append(signal.channel) }
        if !signal.profile.isEmpty { parts.append("\(signal.profile) profile") }
        if !signal.controller.isEmpty { parts.append(signal.controller) }
        if signal.treeMemoryKB > 0 {
            let count = signal.treeProcessCount > 0 ? L10n.format(" · %@개", String(describing: signal.treeProcessCount)) : ""
            parts.append("RSS≈\(signal.treeMemoryText)\(count)")
        }
        return parts.joined(separator: " · ")
    }
}

private struct DevelopmentAssetsSection: View {
    let storage: StorageSnapshot

    var body: some View {
        Section {
            if developerAssets.isEmpty {
                Label(L10n.text("별도 개발 자산이 없습니다"), systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(developerAssets) { item in
                    DevelopmentAssetRow(item: item)
                }
            }
        } header: {
            NativeSectionHeader(
                title: L10n.text("설치된 개발 자산"),
                subtitle: L10n.text("프로젝트 빌드 산출물은 재생성 근거를 다시 검증한 뒤 확보 계획에 넣을 수 있습니다."),
                value: storage.developerText
            )
        }
    }

    private var developerAssets: [StorageItem] {
        storage.developerToolchains.filter { !$0.kind.hasPrefix("simulator_") }
    }
}

private struct DevelopmentAssetRow: View {
    @EnvironmentObject private var model: ScanModel
    let item: StorageItem

    var body: some View {
        WorkspaceStorageItemRow(
            item: item,
            fallbackSymbol: developmentSymbol,
            status: item.measureStatus == "timed_out"
                ? nil
                : (item.cleanupTier == .rebuild ? L10n.text("확보 계획 가능") : L10n.text("개별 판단")),
            actionTitle: item.measureStatus == "timed_out" ? L10n.text("다시 측정") : nil
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
                Text(L10n.message(signal.label))
                    .font(.body.weight(.medium))
                Text(L10n.message(signal.note.isEmpty ? signal.action : signal.note))
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
            Text(signal.risk == "warning" ? L10n.text("실행 중") : L10n.text("확인됨"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 116, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }
}
