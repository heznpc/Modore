import SwiftUI

struct SecurityPage: View {
    @EnvironmentObject private var model: ScanModel
    @State private var showsProtectionDetails = false
    @State private var showsCollectionCoverage = false
    @State private var showsProcesses = false
    @State private var showsBackgroundCpu = false
    @State private var showsNetwork = false
    @State private var showsListeningPorts = false
    @State private var showsAutoruns = false
    @State private var showsRecentInstalls = false
    @State private var showsPrivacyPermissions = false
    @State private var showsDevtoolUpdates = false

    var body: some View {
        Form {
            if let coverage = model.collectionCoverage {
                CollectionCoverageSection(
                    coverage: coverage,
                    isExpanded: $showsCollectionCoverage
                )
            } else if model.summary != nil {
                Section(L10n.text("검사 범위")) {
                    SecurityDetailRow(
                        symbol: "questionmark.circle",
                        title: L10n.text("검사 범위 기록이 없습니다"),
                        detail: L10n.text("이전 형식의 결과이므로 비어 있는 항목을 정상으로 해석할 수 없습니다. 지금 다시 검사하세요.")
                    )
                }
            }

            if !model.truncatedSecuritySections.isEmpty {
                Section(L10n.text("표시 제한")) {
                    SecurityDetailRow(
                        symbol: "doc.badge.ellipsis",
                        title: L10n.text("매우 큰 검사 결과의 행 수를 제한했습니다"),
                        detail: L10n.format("%@ 섹션은 각각 최대 %@개를 표시합니다. 원본 결과를 확인하거나 다시 검사하세요.", String(describing: model.truncatedSecuritySections.joined(separator: ", ")), String(describing: ScanContent.maximumRowsPerSection))
                    )
                }
            }

            if !model.securityFindings.isEmpty {
                SecurityFindingsSection(
                    findings: model.securityFindings,
                    attentionCount: model.securityFindingCount
                )
            }

            if !model.cpuRows.isEmpty || !model.backgroundCpuRows.isEmpty
                || !model.networkRows.isEmpty || !model.listeningPortRows.isEmpty {
                Section {
                    backgroundCpuDisclosure
                    processDisclosure
                    networkDisclosure
                    listeningPortsDisclosure
                } header: {
                    NativeSectionHeader(
                        title: L10n.text("정밀 검사 당시 활동"),
                        subtitle: L10n.text("한 검사 시점에 수집한 실행·통신 스냅샷입니다. 알 수 없음은 안전 판정이 아니며 경로와 맥락을 직접 대조하세요."),
                        value: model.deepScanSnapshotAgeText
                    )
                }
            }

            Section {
                DisclosureGroup(isExpanded: $showsProtectionDetails) {
                    if let security = model.macOSSecurity {
                        SecurityBaselineRows(security: security)
                    } else {
                        Text(L10n.text("macOS 보호 상태를 확인하려면 검사를 실행하세요."))
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    SecurityStatusRow(
                        symbol: "checkmark.shield",
                        title: L10n.text("로컬 진단"),
                        subtitle: model.virusTotalEnabled
                            ? L10n.text("결과는 로컬에 저장되고 SHA-256 해시 조회만 외부로 전송됩니다.")
                            : L10n.text("검사 결과와 저장공간 이력은 이 Mac에만 저장됩니다.")
                    )
                    SecurityStatusRow(
                        symbol: model.virusTotalEnabled ? "network" : "network.slash",
                        title: L10n.text("외부 해시 조회"),
                        subtitle: model.virusTotalEnabled ? L10n.text("VirusTotal 조회가 켜져 있습니다.") : L10n.text("현재 꺼져 있습니다."),
                        value: model.virusTotalEnabled ? L10n.text("켜짐") : L10n.text("꺼짐")
                    )
                } label: {
                    SecurityDisclosureLabel(
                        symbol: protectionSymbol,
                        title: L10n.text("macOS 보호 및 개인정보"),
                        detail: protectionSummary,
                        value: protectionValue
                    )
                }
            } header: {
                NativeSectionHeader(
                    title: L10n.text("정밀 검사 당시 보호 상태"),
                    subtitle: L10n.text("현재 설정을 실시간 감시한 값이 아니라 최근 정밀 검사에서 확인한 스냅샷입니다."),
                    value: model.deepScanSnapshotAgeText
                )
            }

            if !model.privacyPermissionRows.isEmpty {
                Section {
                    privacyPermissionsDisclosure
                } header: {
                    NativeSectionHeader(
                        title: L10n.text("정밀 검사 당시 개인정보 권한"),
                        subtitle: L10n.text("카메라·마이크 접근을 허용받은 앱 목록입니다. 지금 사용 중인지가 아니라 접근 자체가 가능한지를 보여주며, 대부분은 정상적인 권한입니다."),
                        value: L10n.format("%@개 · %@", String(describing: model.privacyPermissionRows.count), String(describing: model.deepScanSnapshotAgeText))
                    )
                }
            }

            if !model.devtoolUpdateRows.isEmpty {
                Section {
                    devtoolUpdatesDisclosure
                } header: {
                    NativeSectionHeader(
                        title: L10n.text("정밀 검사 당시 개발도구 업데이트"),
                        subtitle: L10n.text("Homebrew로 설치한 패키지 중 새 버전이 있는 항목입니다. 업데이트를 실행하지 않으며, 로컬에 이미 있는 정보만 비교합니다."),
                        value: L10n.format("%@개 · %@", String(describing: model.devtoolUpdateRows.count), String(describing: model.deepScanSnapshotAgeText))
                    )
                }
            }

            if !model.autorunRows.isEmpty || !model.recentInstalls.isEmpty {
                Section {
                    autorunDisclosure
                    installDisclosure
                } header: {
                    NativeSectionHeader(
                        title: L10n.text("정밀 검사 당시 시스템 변경"),
                        subtitle: L10n.text("자동 실행 항목과 최근 설치 앱을 한 검사 시점의 스냅샷으로 표시합니다."),
                        value: model.deepScanSnapshotAgeText
                    )
                }
            }
        }
        .macSettingsFormStyle()
        .confirmationDialog(
            L10n.format("\"%@\"를 로그인 항목에서 제거할까요?", String(describing: model.pendingLoginItemRemoval?.name ?? "")),
            isPresented: Binding(
                get: { model.pendingLoginItemRemoval != nil },
                set: { if !$0 { model.cancelLoginItemRemoval() } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("제거"), role: .destructive) {
                model.confirmLoginItemRemoval()
            }
            Button(L10n.text("취소"), role: .cancel) {
                model.cancelLoginItemRemoval()
            }
        } message: {
            Text(L10n.text("로그인할 때 이 항목이 더 이상 자동으로 열리지 않습니다. 앱 자체는 지워지지 않습니다."))
        }
    }

    @ViewBuilder
    private var privacyPermissionsDisclosure: some View {
        if !model.privacyPermissionRows.isEmpty {
            DisclosureGroup(isExpanded: $showsPrivacyPermissions) {
                ForEach(model.privacyPermissionRows) { row in
                    SecurityDetailRow(
                        symbol: row.isCamera ? "camera" : "mic",
                        title: row.client,
                        detail: row.isCamera ? L10n.text("카메라 접근 허용됨") : L10n.text("마이크 접근 허용됨")
                    )
                }
            } label: {
                SecurityDisclosureLabel(
                    symbol: "camera",
                    title: L10n.text("카메라·마이크 권한"),
                    detail: L10n.text("전체 디스크 접근 권한이 있는 경우에만 확인됩니다."),
                    value: L10n.format("%@개", String(describing: model.privacyPermissionRows.count))
                )
            }
        }
    }

    @ViewBuilder
    private var devtoolUpdatesDisclosure: some View {
        if !model.devtoolUpdateRows.isEmpty {
            DisclosureGroup(isExpanded: $showsDevtoolUpdates) {
                ForEach(model.devtoolUpdateRows) { row in
                    SecurityDetailRow(
                        symbol: row.pinned ? "pin" : "shippingbox",
                        title: row.name,
                        detail: row.pinned
                            ? L10n.format("%@ → %@ · 고정해 둔 패키지입니다", String(describing: row.current), String(describing: row.latest))
                            : "\(row.current) → \(row.latest)"
                    )
                }
            } label: {
                SecurityDisclosureLabel(
                    symbol: "shippingbox",
                    title: L10n.text("Homebrew 패키지"),
                    detail: L10n.text("brew outdated 기준이며, 네트워크 조회 없이 로컬 정보만 비교합니다."),
                    value: L10n.format("%@개", String(describing: model.devtoolUpdateRows.count))
                )
            }
        }
    }

    @ViewBuilder
    private var backgroundCpuDisclosure: some View {
        if !model.backgroundCpuRows.isEmpty {
            DisclosureGroup(isExpanded: $showsBackgroundCpu) {
                ForEach(model.backgroundCpuRows) { row in
                    if row.requiresAttention {
                        SecurityRiskDetailRow(
                            symbol: "gauge.with.needle",
                            title: backgroundCpuTitle(row),
                            detail: backgroundCpuMetadata(row),
                            risk: row.risk
                        )
                    } else {
                        SecurityDetailRow(
                            symbol: "gauge.with.needle",
                            title: backgroundCpuTitle(row),
                            detail: backgroundCpuMetadata(row)
                        )
                    }
                }
            } label: {
                SecurityDisclosureLabel(
                    symbol: "gauge.with.needle",
                    title: L10n.text("관측 구간 CPU 사용"),
                    detail: backgroundCpuSummary,
                    value: L10n.format("%@개", String(describing: model.backgroundCpuRows.count))
                )
            }
        }
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
                    title: L10n.text("실행 프로세스"),
                    detail: evidenceSummary(attention: model.attentionCpuRows.count),
                    value: L10n.format("%@개", String(describing: model.cpuRows.count))
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
                    title: L10n.text("외부 네트워크 연결"),
                    detail: evidenceSummary(attention: model.attentionNetworkRows.count),
                    value: L10n.format("%@개", String(describing: model.networkRows.count))
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
                    title: L10n.text("수신 대기 포트"),
                    detail: evidenceSummary(attention: model.attentionListeningPortRows.count),
                    value: L10n.format("%@개", String(describing: model.listeningPortRows.count))
                )
            }
        }
    }

    @ViewBuilder
    private var autorunDisclosure: some View {
        if !model.autorunRows.isEmpty {
            DisclosureGroup(isExpanded: $showsAutoruns) {
                ForEach(model.autorunRows) { row in
                    Group {
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
                    .opacity(model.loginItemActionInFlight == row.entry ? 0.5 : 1)
                    .contextMenu {
                        if row.category == "Login Item" {
                            Button(L10n.text("로그인 항목에서 제거…")) {
                                model.previewLoginItemRemoval(row.entry)
                            }
                            .disabled(model.loginItemActionInFlight != nil)
                        }
                    }
                }
            } label: {
                SecurityDisclosureLabel(
                    symbol: "gearshape.2",
                    title: L10n.text("자동 실행 항목"),
                    detail: systemChangeSummary(
                        attention: model.autorunRows.filter { $0.risk == "danger" || $0.risk == "warning" }.count,
                        fallback: L10n.text("로그인이나 부팅 때 다시 시작됩니다.")
                    ),
                    value: L10n.format("%@개", String(describing: model.autorunRows.count))
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
                    title: L10n.text("최근 설치 앱"),
                    detail: systemChangeSummary(
                        attention: model.recentInstalls.filter { $0.risk == "danger" || $0.risk == "warning" }.count,
                        fallback: L10n.text("최근 30일 안에 설치되거나 변경됐습니다.")
                    ),
                    value: L10n.format("%@개", String(describing: model.recentInstalls.count))
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
        guard let security = model.macOSSecurity else { return L10n.text("검사 결과가 없습니다.") }
        if security.gatekeeperEnabled && security.sipEnabled && !security.xprotectVersion.isEmpty {
            return L10n.text("Gatekeeper, 시스템 무결성 보호, XProtect가 확인됐습니다.")
        }
        return L10n.text("확인이 필요한 macOS 보호 설정이 있습니다.")
    }

    private var protectionValue: String {
        protectionSymbol == "checkmark.shield" ? L10n.text("정상") : L10n.text("확인 필요")
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

    private func backgroundCpuTitle(_ row: BackgroundCpuRow) -> String {
        row.isDetachedFromAnApp ? L10n.format("%@ · 터미널에서 시작됨", String(describing: row.name)) : row.name
    }

    private func backgroundCpuMetadata(_ row: BackgroundCpuRow) -> String {
        var values = [String(format: L10n.text("관측 구간 %.1f%%"), row.cpuPercent), "PID \(row.pid)"]
        // 책임 조상이 자신과 다를 때만 밝힌다. 같으면 중복이고, 다를 때가 바로
        // 프로세스 이름만 보고 엉뚱한 앱을 범인으로 읽게 되는 경우다.
        if !row.selfResponsible && !row.responsibleName.isEmpty {
            values.append(L10n.format("시작: %@ · PID %@", String(describing: row.responsibleName), String(describing: row.responsiblePid)))
        }
        if !row.note.isEmpty { values.append(row.note) }
        return values.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var backgroundCpuSummary: String {
        let window = model.backgroundCpuRows.first?.windowSeconds ?? 0
        let measured = window > 0
            ? L10n.format("%@초 동안 실제로 CPU를 쓴 프로세스입니다.", String(describing: window))
            : L10n.text("관측 구간 동안 실제로 CPU를 쓴 프로세스입니다.")
        let detached = model.detachedBackgroundCpuRows.count
        guard detached > 0 else {
            return measured + L10n.text(" 아래 실행 프로세스 목록의 값은 생애 평균이라 다를 수 있습니다.")
        }
        return measured
            + L10n.format(" 그중 %@개는 터미널에서 시작돼, 관련 앱을 닫아도 멈추지 않습니다.", String(describing: detached))
    }

    private func processMetadata(_ row: CpuRow) -> String {
        var values = [row.path, "PID \(row.pid)"]
        values.append(String(format: L10n.text("CPU %.1f%% · 메모리 %.1fMB"), row.cpu, row.memoryMB))
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
        return row.port > 0 ? L10n.format("%@ · 포트 %@", String(describing: owner), String(describing: row.port)) : owner
    }

    private func listeningPortMetadata(_ row: ListeningPortRow) -> String {
        var values: [String] = []
        if row.pid > 0 { values.append("PID \(row.pid)") }
        values.append(contentsOf: [row.path, row.note])
        return values.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func evidenceSummary(attention: Int) -> String {
        attention > 0
            ? L10n.format("확인 필요 %@개를 포함합니다. 행을 펼쳐 경로와 맥락을 대조하세요.", String(describing: attention))
            : L10n.text("현재 스냅샷의 전체 행입니다. 알 수 없음 항목도 직접 확인할 수 있습니다.")
    }

    private func systemChangeSummary(attention: Int, fallback: String) -> String {
        attention > 0 ? L10n.format("확인 표시 %@개가 있습니다. 펼쳐 설치 맥락을 대조하세요.", String(describing: attention)) : fallback
    }
}
