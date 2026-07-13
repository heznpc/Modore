import SwiftUI

struct SecurityPage: View {
    @EnvironmentObject private var model: ScanModel
    @State private var showsProtectionDetails = false
    @State private var showsCollectionCoverage = false
    @State private var showsProcesses = false
    @State private var showsNetwork = false
    @State private var showsAutoruns = false
    @State private var showsRecentInstalls = false

    var body: some View {
        Form {
            if let coverage = model.collectionCoverage {
                CollectionCoverageSection(
                    coverage: coverage,
                    isExpanded: $showsCollectionCoverage
                )
            } else if model.summary != nil {
                Section("검사 범위") {
                    SecurityDetailRow(
                        symbol: "questionmark.circle",
                        title: "검사 범위 기록이 없습니다",
                        detail: "이전 형식의 결과이므로 비어 있는 항목을 정상으로 해석할 수 없습니다. 지금 다시 검사하세요."
                    )
                }
            }

            if !model.truncatedSecuritySections.isEmpty {
                Section("표시 제한") {
                    SecurityDetailRow(
                        symbol: "doc.badge.ellipsis",
                        title: "매우 큰 검사 결과의 행 수를 제한했습니다",
                        detail: "\(model.truncatedSecuritySections.joined(separator: ", ")) 섹션은 각각 최대 \(ScanContent.maximumRowsPerSection)개를 표시합니다. 원본 결과를 확인하거나 다시 검사하세요."
                    )
                }
            }

            if !model.securityFindings.isEmpty {
                SecurityFindingsSection(
                    findings: model.securityFindings,
                    attentionCount: model.securityFindingCount
                )
            }

            if !model.attentionCpuRows.isEmpty || !model.attentionNetworkRows.isEmpty {
                Section("비정상 동작 신호") {
                    processDisclosure
                    networkDisclosure
                }
            }

            Section("보호 상태") {
                DisclosureGroup(isExpanded: $showsProtectionDetails) {
                    if let security = model.macOSSecurity {
                        SecurityBaselineRows(security: security)
                    } else {
                        Text("macOS 보호 상태를 확인하려면 검사를 실행하세요.")
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    SecurityStatusRow(
                        symbol: "checkmark.shield",
                        title: "로컬 진단",
                        subtitle: model.virusTotalEnabled
                            ? "결과는 로컬에 저장되고 SHA-256 해시 조회만 외부로 전송됩니다."
                            : "검사 결과와 저장공간 이력은 이 Mac에만 저장됩니다."
                    )
                    SecurityStatusRow(
                        symbol: model.virusTotalEnabled ? "network" : "network.slash",
                        title: "외부 해시 조회",
                        subtitle: model.virusTotalEnabled ? "VirusTotal 조회가 켜져 있습니다." : "현재 꺼져 있습니다.",
                        value: model.virusTotalEnabled ? "켜짐" : "꺼짐"
                    )
                } label: {
                    SecurityDisclosureLabel(
                        symbol: protectionSymbol,
                        title: "macOS 보호 및 개인정보",
                        detail: protectionSummary,
                        value: protectionValue
                    )
                }
            }

            if !model.autorunRows.isEmpty || !model.recentInstalls.isEmpty {
                Section("시스템 변경") {
                    autorunDisclosure
                    installDisclosure
                }
            }
        }
        .macSettingsFormStyle()
    }

    @ViewBuilder
    private var processDisclosure: some View {
        if !model.attentionCpuRows.isEmpty {
            DisclosureGroup(isExpanded: $showsProcesses) {
                ForEach(model.attentionCpuRows) { row in
                    SecurityRiskDetailRow(
                        symbol: "waveform.path.ecg",
                        title: row.name,
                        detail: processMetadata(row),
                        risk: row.risk
                    )
                }
            } label: {
                SecurityDisclosureLabel(
                    symbol: "waveform.path.ecg",
                    title: "확인이 필요한 프로세스",
                    detail: "실행 경로와 사용량을 함께 확인하세요.",
                    value: "\(model.attentionCpuRows.count)개"
                )
            }
        }
    }

    @ViewBuilder
    private var networkDisclosure: some View {
        if !model.attentionNetworkRows.isEmpty {
            DisclosureGroup(isExpanded: $showsNetwork) {
                ForEach(model.attentionNetworkRows) { row in
                    SecurityRiskDetailRow(
                        symbol: "network",
                        title: row.process,
                        detail: networkMetadata(row),
                        risk: row.risk
                    )
                }
            } label: {
                SecurityDisclosureLabel(
                    symbol: "network",
                    title: "확인이 필요한 네트워크 연결",
                    detail: "원격 주소와 연결 프로세스를 확인하세요.",
                    value: "\(model.attentionNetworkRows.count)개"
                )
            }
        }
    }

    @ViewBuilder
    private var autorunDisclosure: some View {
        if !model.autorunRows.isEmpty {
            DisclosureGroup(isExpanded: $showsAutoruns) {
                ForEach(model.autorunRows) { row in
                    if row.risk == "danger" || row.risk == "warning" {
                        SecurityRiskDetailRow(
                            symbol: "gearshape.2",
                            title: row.entry,
                            detail: autorunMetadata(row),
                            risk: row.risk
                        )
                    } else {
                        SecurityDetailRow(
                            symbol: "gearshape.2",
                            title: row.entry,
                            detail: autorunMetadata(row)
                        )
                    }
                }
            } label: {
                SecurityDisclosureLabel(
                    symbol: "gearshape.2",
                    title: "자동 실행 항목",
                    detail: "로그인이나 부팅 때 다시 시작됩니다.",
                    value: "\(model.autorunRows.count)개"
                )
            }
        }
    }

    @ViewBuilder
    private var installDisclosure: some View {
        if !model.recentInstalls.isEmpty {
            DisclosureGroup(isExpanded: $showsRecentInstalls) {
                ForEach(model.recentInstalls) { install in
                    SecurityDetailRow(
                        symbol: "shippingbox",
                        title: install.name,
                        detail: installMetadata(install)
                    )
                }
            } label: {
                SecurityDisclosureLabel(
                    symbol: "shippingbox",
                    title: "최근 설치 앱",
                    detail: "최근 30일 안에 설치되거나 변경됐습니다.",
                    value: "\(model.recentInstalls.count)개"
                )
            }
        }
    }

    private var protectionSymbol: String {
        guard let security = model.macOSSecurity else { return "questionmark.shield" }
        return security.gatekeeperEnabled && security.sipEnabled && !security.xprotectVersion.isEmpty
            ? "checkmark.shield"
            : "exclamationmark.shield"
    }

    private var protectionSummary: String {
        guard let security = model.macOSSecurity else { return "검사 결과가 없습니다." }
        if security.gatekeeperEnabled && security.sipEnabled && !security.xprotectVersion.isEmpty {
            return "Gatekeeper, 시스템 무결성 보호, XProtect가 확인됐습니다."
        }
        return "확인이 필요한 macOS 보호 설정이 있습니다."
    }

    private var protectionValue: String {
        protectionSymbol == "checkmark.shield" ? "정상" : "확인 필요"
    }

    private func autorunMetadata(_ row: AutorunRow) -> String {
        [row.category, row.image, row.note]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func installMetadata(_ install: RecentInstallRow) -> String {
        [install.installDate, install.publisher, install.note]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func processMetadata(_ row: CpuRow) -> String {
        var values = [row.path, "PID \(row.pid)"]
        values.append(String(format: "CPU %.1f%% · 메모리 %.1fMB", row.cpu, row.memoryMB))
        if !row.note.isEmpty { values.append(row.note) }
        return values.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func networkMetadata(_ row: NetworkRow) -> String {
        let endpoint = row.remotePort > 0
            ? "\(row.remoteAddress):\(row.remotePort)"
            : row.remoteAddress
        return [endpoint, row.note].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
