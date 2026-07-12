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
        .accessibilityLabel("개발 환경 항목")
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
                title: "현재 실행 신호",
                subtitle: "정리 뒤 공간을 다시 채울 수 있는 작업입니다.",
                value: "\(signals.count)종"
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
                title: "브라우저 자동화",
                subtitle: "일반 Chrome과 자동화 브라우저의 충돌 및 잔류 여부를 확인합니다.",
                value: summaryValue
            )
        }
    }

    private var browserRoots: [RuntimeSignal] {
        storage.runtimeSignals.filter { $0.kind == "browser_automation_root" }
    }

    private var summaryValue: String {
        switch storage.browserAutomation.verdict {
        case "orphaned": return "잔류 \(storage.browserAutomation.orphanedRootCount)개"
        case "conflict_possible": return "충돌 가능"
        case "isolated_active": return "격리 실행 중"
        default: return "현재 신호 없음"
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
                Text(status.note)
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
        case "orphaned": return "소유 작업을 찾지 못한 오래된 자동화가 있습니다"
        case "conflict_possible": return "기본 Chrome을 사용하는 자동화가 있습니다"
        case "isolated_active": return "격리 브라우저에서 자동화 중입니다"
        default: return "현재 자동화 충돌 신호가 없습니다"
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
        status.rootCount > 0 ? "\(status.rootCount)개 루트" : "확인됨"
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
                Text("Playwright 전역 격리 설정")
                    .font(.body.weight(.medium))
                Text(configurationDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(status.globalIsolationConfigured ? "격리됨" : "미설정")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private var configurationDetail: String {
        if status.globalIsolationConfigured {
            return "\(status.configLocation)에서 Chromium 격리를 확인했습니다."
        }
        if status.globalConfigPresent {
            return "설정 파일은 있지만 Chromium 격리가 강제되지 않습니다."
        }
        return "전역 설정 파일이 없습니다. 자동화 도구의 기본 채널 선택을 확인하세요."
    }
}

private struct BrowserAutomationRootRow: View {
    let signal: RuntimeSignal

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isOrphanCandidate ? "questionmark.circle" : "play.circle")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(signal.label)
                    .font(.body.weight(.medium))
                Text(metadata)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(signal.action)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(isOrphanCandidate ? "잔류 후보" : "실행 중")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private var isOrphanCandidate: Bool {
        signal.state == "orphan_candidate" || signal.state == "orphaned"
    }

    private var metadata: String {
        var parts = ["PID \(signal.pid)", "부모 \(signal.parentPid)"]
        if !signal.elapsed.isEmpty { parts.append("실행 \(signal.elapsed)") }
        if !signal.channel.isEmpty { parts.append(signal.channel) }
        if !signal.profile.isEmpty { parts.append("\(signal.profile) profile") }
        if !signal.controller.isEmpty { parts.append(signal.controller) }
        return parts.joined(separator: " · ")
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
