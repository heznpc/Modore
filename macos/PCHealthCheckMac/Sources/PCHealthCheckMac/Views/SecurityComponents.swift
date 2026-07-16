import SwiftUI

struct CollectionCoverageSection: View {
    let coverage: CollectionCoverage
    @Binding var isExpanded: Bool

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(coverage.sources) { source in
                    SecurityStatusRow(
                        symbol: source.status == "ok" ? "checkmark.circle" : issueSymbol(source),
                        title: source.label,
                        subtitle: source.detail.isEmpty ? source.statusText : source.detail,
                        value: source.statusText
                    )
                }
            } label: {
                SecurityDisclosureLabel(
                    symbol: coverage.allSourcesComplete ? "checkmark.shield" : "questionmark.shield",
                    title: coverageTitle,
                    detail: coverageDetail,
                    value: coverage.coverageText
                )
            }
        } header: {
            NativeSectionHeader(
                title: "검사 범위",
                subtitle: "무엇을 실제로 확인했는지와 누락된 수집기를 구분합니다.",
                value: coverage.complete
                    ? "\(coverage.coverageText) · \(coverage.allCoverageText)"
                    : "판단 보류"
            )
        }
    }

    private var coverageTitle: String {
        guard coverage.complete else { return "필수 검사 범위가 불완전합니다" }
        return coverage.allSourcesComplete
            ? "모든 검사 범위를 완료했습니다"
            : "필수 검사 범위를 완료했습니다"
    }

    private var coverageDetail: String {
        guard coverage.complete else {
            return "완료하지 못한 필수 수집기가 있어 안전 여부를 확정하지 않습니다."
        }
        guard !coverage.optionalIssues.isEmpty else {
            return "모든 수집기가 응답했습니다. 정상 판정은 이 범위 안에서만 유효합니다."
        }
        return "선택 수집기 \(coverage.optionalIssues.count)개가 응답하지 않았습니다. 정상 판정은 완료된 범위 안에서만 유효합니다."
    }

    private func issueSymbol(_ source: CollectionSourceStatus) -> String {
        switch source.status {
        case "permission_denied": return "lock"
        case "timed_out": return "clock"
        case "unavailable": return "slash.circle"
        default: return "xmark.circle"
        }
    }
}

struct SecurityBaselineRows: View {
    let security: MacOSSecurityStatus

    var body: some View {
        SecurityBaselineRow(
            title: "Gatekeeper",
            subtitle: "다운로드한 앱의 서명과 공증을 확인합니다.",
            value: security.gatekeeperEnabled ? "켜짐" : "확인 필요",
            isHealthy: security.gatekeeperEnabled
        )
        SecurityBaselineRow(
            title: "시스템 무결성 보호",
            subtitle: "macOS 핵심 영역의 변경을 제한합니다.",
            value: security.sipEnabled ? "켜짐" : "확인 필요",
            isHealthy: security.sipEnabled
        )
        SecurityBaselineRow(
            title: "XProtect",
            subtitle: "Apple의 내장 악성코드 정의입니다.",
            value: security.xprotectVersion.isEmpty ? "확인 필요" : "버전 \(security.xprotectVersion)",
            isHealthy: security.xprotectVersion.isEmpty ? false : nil
        )
    }
}

struct SecurityDisclosureLabel: View {
    let symbol: String
    let title: String
    let detail: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Text(value)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }
}

struct SecurityDetailRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct SecurityRiskDetailRow: View {
    let symbol: String
    let title: String
    let detail: String
    let risk: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: risk == "danger" ? "exclamationmark.triangle" : symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(risk == "danger" ? Color.red : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(risk == "danger" ? "위험" : "확인 필요"), \(detail)")
    }
}

struct SecurityStatusRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    var value: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if let value {
                Text(value).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct StorageAccessIssuesSection: View {
    let issues: [StorageAccessIssue]
    let openSettings: () -> Void

    var body: some View {
        Section("읽기 제한") {
            ForEach(issues) { issue in
                SecurityDetailRow(
                    symbol: "lock.trianglebadge.exclamationmark",
                    title: issue.label,
                    detail: "macOS가 읽기를 제한했습니다 · \(issue.path)"
                )
            }
            Button("전체 디스크 접근 권한 열기", systemImage: "gear", action: openSettings)
        }
    }
}

struct SecurityFindingsSection: View {
    let findings: [ScanFinding]
    let attentionCount: Int

    var body: some View {
        Section {
            ForEach(findings) { finding in
                SecurityFindingRow(finding: finding)
            }
        } header: {
            NativeSectionHeader(
                title: "확인 필요",
                subtitle: "보안 관련 진단 결과입니다.",
                value: "\(attentionCount)건"
            )
        }
    }
}

private struct SecurityBaselineRow: View {
    let title: String
    let subtitle: String
    let value: String
    let isHealthy: Bool?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusSymbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(statusTint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Text(value).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var statusSymbol: String {
        guard let isHealthy else { return "shield" }
        return isHealthy ? "checkmark.shield" : "exclamationmark.shield"
    }

    private var statusTint: Color {
        .secondary
    }
}

private struct SecurityFindingRow: View {
    let finding: ScanFinding

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: findingSymbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(findingColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title).font(.body.weight(.medium))
                Text(finding.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.vertical, 5)
    }

    private var findingSymbol: String {
        switch finding.level {
        case "danger": return "exclamationmark.triangle"
        case "warning": return "info.circle"
        case "safe": return "checkmark.circle"
        default: return "info.circle"
        }
    }

    private var findingColor: Color {
        switch finding.level {
        case "danger": return .red
        default: return .secondary
        }
    }
}
