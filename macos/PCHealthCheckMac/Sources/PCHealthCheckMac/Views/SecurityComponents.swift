import SwiftUI

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

struct SecurityAccessIssuesSection: View {
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
    let summary: ScanSummary?

    var body: some View {
        Section {
            ForEach(findings) { finding in
                SecurityFindingRow(finding: finding)
            }
        } header: {
            NativeSectionHeader(
                title: "확인 필요",
                subtitle: summary?.message ?? "",
                value: "\(attentionCount)건"
            )
        }
    }

    private var attentionCount: Int {
        max(
            summary?.attentionCount ?? 0,
            findings.filter { $0.level == "danger" || $0.level == "warning" }.count
        )
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
