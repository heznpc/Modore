import SwiftUI

struct SecurityPage: View {
    @EnvironmentObject private var model: ScanModel
    @State private var showsProtectionDetails = false
    @State private var showsCollectionCoverage = false
    @State private var showsProcesses = false
    @State private var showsNetwork = false
    @State private var showsListeningPorts = false
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

            if !model.cpuRows.isEmpty || !model.networkRows.isEmpty || !model.listeningPortRows.isEmpty {
                Section {
                    processDisclosure
                    networkDisclosure
                    listeningPortsDisclosure
                } header: {
                    NativeSectionHeader(
                        title: "현재 활동 증거",
                        subtitle: "판단에 사용한 실행·통신 스냅샷입니다. 알 수 없음은 안전 판정이 아니며 경로와 맥락을 직접 대조하세요.",
                        value: model.storageSnapshotAgeText
                    )
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
        if !model.cpuRows.isEmpty {
            DisclosureGroup(isExpanded: $showsProcesses) {
                ForEach(model.cpuRows) { row in
                    if row.requiresAttention {
                        SecurityRiskDetailRow(
                            symbol: "waveform.path.ecg",
                            title: row.name,
                            detail: processMetadata(row),
                            risk: row.risk
                        )
                    } else {
                        SecurityDetailRow(
                            symbol: "waveform.path.ecg",
                            title: row.name,
                            detail: processMetadata(row)
                        )
                    }
                }
            } label: {
                SecurityDisclosureLabel(
                    symbol: "waveform.path.ecg",
                    title: "실행 프로세스",
                    detail: evidenceSummary(attention: model.attentionCpuRows.count),
                    value: "\(model.cpuRows.count)개"
                )
            }
        }
    }

    @ViewBuilder
    private var networkDisclosure: some View {
        if !model.networkRows.isEmpty {
            DisclosureGroup(isExpanded: $showsNetwork) {
                ForEach(model.networkRows) { row in
                    if row.requiresAttention {
                        SecurityRiskDetailRow(
                            symbol: "network",
                            title: row.process,
                            detail: networkMetadata(row),
                            risk: row.risk
                        )
                    } else {
                        SecurityDetailRow(
                            symbol: "network",
                            title: row.process,
                            detail: networkMetadata(row)
                        )
                    }
                }
            } label: {
                SecurityDisclosureLabel(
                    symbol: "network",
                    title: "외부 네트워크 연결",
                    detail: evidenceSummary(attention: model.attentionNetworkRows.count),
                    value: "\(model.networkRows.count)개"
                )
            }
        }
    }

    @ViewBuilder
    private var listeningPortsDisclosure: some View {
        if !model.listeningPortRows.isEmpty {
            DisclosureGroup(isExpanded: $showsListeningPorts) {
                ForEach(model.listeningPortRows) { row in
                    if row.requiresAttention {
                        SecurityRiskDetailRow(
                            symbol: "dot.radiowaves.left.and.right",
                            title: listeningPortTitle(row),
                            detail: listeningPortMetadata(row),
                            risk: row.risk
                        )
                    } else {
                        SecurityDetailRow(
                            symbol: "dot.radiowaves.left.and.right",
                            title: listeningPortTitle(row),
                            detail: listeningPortMetadata(row)
                        )
                    }
                }
            } label: {
                SecurityDisclosureLabel(
                    symbol: "dot.radiowaves.left.and.right",
                    title: "수신 대기 포트",
                    detail: evidenceSummary(attention: model.attentionListeningPortRows.count),
                    value: "\(model.listeningPortRows.count)개"
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
                    detail: systemChangeSummary(
                        attention: model.autorunRows.filter { $0.risk == "danger" || $0.risk == "warning" }.count,
                        fallback: "로그인이나 부팅 때 다시 시작됩니다."
                    ),
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
                    if install.risk == "danger" || install.risk == "warning" {
                        SecurityRiskDetailRow(
                            symbol: "shippingbox",
                            title: install.name,
                            detail: installMetadata(install),
                            risk: install.risk
                        )
                    } else {
                        SecurityDetailRow(
                            symbol: "shippingbox",
                            title: install.name,
                            detail: installMetadata(install)
                        )
                    }
                }
            } label: {
                SecurityDisclosureLabel(
                    symbol: "shippingbox",
                    title: "최근 설치 앱",
                    detail: systemChangeSummary(
                        attention: model.recentInstalls.filter { $0.risk == "danger" || $0.risk == "warning" }.count,
                        fallback: "최근 30일 안에 설치되거나 변경됐습니다."
                    ),
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
        var values = [endpoint]
        if row.pid > 0 { values.append("PID \(row.pid)") }
        values.append(contentsOf: [row.path, row.note])
        return values.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func listeningPortTitle(_ row: ListeningPortRow) -> String {
        let owner = row.process.isEmpty ? row.name : row.process
        return row.port > 0 ? "\(owner) · 포트 \(row.port)" : owner
    }

    private func listeningPortMetadata(_ row: ListeningPortRow) -> String {
        var values: [String] = []
        if row.pid > 0 { values.append("PID \(row.pid)") }
        values.append(contentsOf: [row.path, row.note])
        return values.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func evidenceSummary(attention: Int) -> String {
        attention > 0
            ? "확인 필요 \(attention)개를 포함합니다. 행을 펼쳐 경로와 맥락을 대조하세요."
            : "현재 스냅샷의 전체 행입니다. 알 수 없음 항목도 직접 확인할 수 있습니다."
    }

    private func systemChangeSummary(attention: Int, fallback: String) -> String {
        attention > 0 ? "확인 표시 \(attention)개가 있습니다. 펼쳐 설치 맥락을 대조하세요." : fallback
    }
}
