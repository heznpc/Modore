import AppKit
import SwiftUI

struct SecurityPage: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        Form {
            if let security = model.macOSSecurity {
                SecurityBaselineSection(security: security)
            }
            SecurityPrivacySection(virusTotalEnabled: model.virusTotalEnabled)
            if !model.autorunRows.isEmpty {
                SecurityAutorunsSection(rows: model.autorunRows)
            }
            if !model.recentInstalls.isEmpty {
                SecurityRecentInstallsSection(installs: model.recentInstalls)
            }
            if let issues = model.storage?.accessIssues, !issues.isEmpty {
                SecurityAccessIssuesSection(
                    issues: issues,
                    openSettings: model.openFullDiskAccessSettings
                )
            }
            SecurityFindingsSection(findings: model.findings, summary: model.summary)
        }
        .macSettingsFormStyle()
    }
}

struct SecurityBaselineSection: View {
    let security: MacOSSecurityStatus

    var body: some View {
        Section("macOS 보호 상태") {
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
}

struct SecurityPrivacySection: View {
    let virusTotalEnabled: Bool

    var body: some View {
        Section("개인정보 및 외부 연결") {
            SecurityStatusRow(
                symbol: "checkmark.shield",
                tint: .green,
                title: "로컬 진단",
                subtitle: virusTotalEnabled
                    ? "결과와 이력은 로컬에 저장되며 SHA-256 해시 조회만 외부로 전송됩니다."
                    : "검사 결과와 저장공간 이력은 이 Mac에만 저장됩니다."
            )
            SecurityStatusRow(
                symbol: virusTotalEnabled ? "network" : "network.slash",
                tint: virusTotalEnabled ? .orange : .gray,
                title: "외부 해시 조회",
                subtitle: virusTotalEnabled ? "VirusTotal SHA-256 조회가 켜져 있습니다." : "현재 꺼져 있습니다.",
                value: virusTotalEnabled ? "켜짐" : "꺼짐"
            )
        }
    }
}

struct SecurityStatusRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    var value: String?

    var body: some View {
        HStack(spacing: 12) {
            NativeStatusGlyph(symbol: symbol, tint: tint)
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

struct SecurityAutorunsSection: View {
    let rows: [AutorunRow]

    var body: some View {
        Section {
            ForEach(Array(rows.prefix(8))) { row in
                HStack(alignment: .top, spacing: 12) {
                    NativeStatusGlyph(symbol: "gearshape.2", tint: .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.entry).font(.body.weight(.medium))
                        Text("\(row.category) · \(row.image)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            if rows.count > 8 {
                Text("그 외 \(rows.count - 8)개")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            NativeSectionHeader(
                title: "자동 실행 항목",
                subtitle: "로그인이나 부팅 때 다시 시작되는 항목입니다.",
                value: "\(rows.count)개"
            )
        }
    }
}

struct SecurityRecentInstallsSection: View {
    let installs: [RecentInstallRow]

    var body: some View {
        Section {
            ForEach(Array(installs.prefix(6))) { install in
                HStack(alignment: .top, spacing: 12) {
                    NativeStatusGlyph(symbol: "shippingbox", tint: .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(install.name).font(.body.weight(.medium))
                        Text(metadata(for: install))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        } header: {
            NativeSectionHeader(
                title: "최근 설치 앱",
                subtitle: "최근 30일 안에 설치되거나 변경된 앱입니다.",
                value: "\(installs.count)개"
            )
        }
    }

    private func metadata(for install: RecentInstallRow) -> String {
        [install.installDate, install.publisher]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

struct SecurityAccessIssuesSection: View {
    let issues: [StorageAccessIssue]
    let openSettings: () -> Void

    var body: some View {
        Section {
            ForEach(issues) { issue in
                HStack(alignment: .top, spacing: 12) {
                    NativeStatusGlyph(symbol: "lock.trianglebadge.exclamationmark", tint: .orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(issue.label).font(.body.weight(.medium))
                        Text("macOS가 이 경로의 읽기를 제한했습니다.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(issue.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            Button("전체 디스크 접근 권한 열기", systemImage: "gear", action: openSettings)
        } header: {
            NativeSectionHeader(
                title: "읽기 제한",
                subtitle: "macOS 개인정보 보호 설정으로 빠진 영역입니다."
            )
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
                title: "진단 결과",
                subtitle: summary?.message ?? "",
                value: "\(summary?.warningCount ?? 0)건 확인"
            )
        }
    }
}

struct SecurityBaselineRow: View {
    let title: String
    let subtitle: String
    let value: String
    let isHealthy: Bool?

    var body: some View {
        HStack(spacing: 12) {
            NativeStatusGlyph(
                symbol: statusSymbol,
                tint: statusTint
            )
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
        guard let isHealthy else { return .secondary }
        return isHealthy ? .green : .orange
    }
}

struct SecurityFindingRow: View {
    let finding: ScanFinding

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            NativeStatusGlyph(symbol: findingSymbol, tint: findingColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(finding.title).font(.body.weight(.medium))
                Text(finding.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var findingSymbol: String {
        switch finding.level {
        case "danger": return "exclamationmark.triangle"
        case "warning": return "exclamationmark"
        case "safe": return "checkmark"
        default: return "info"
        }
    }

    private var findingColor: Color {
        switch finding.level {
        case "danger": return .red
        case "warning": return .orange
        case "safe": return .green
        default: return .blue
        }
    }
}
