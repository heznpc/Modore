import AppKit
import Foundation
import SwiftUI

@main
struct PCHealthCheckMacApp: App {
    @StateObject private var model = ScanModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1120, minHeight: 740)
        }
        .windowStyle(.titleBar)
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
        } detail: {
            ReportPane()
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HeaderBlock()
                SecurityPrivacyBlock()
                StatusBlock()
                ActionBlock()
                PermissionBlock()
                LogBlock()
            }
            .padding(18)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct HeaderBlock: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("PC 건강검진 Mac Edition", systemImage: "stethoscope")
                .font(.title2.bold())
            Text("macOS가 System Data, Developer, macOS 같은 막대로 숨긴 원인을 실제 경로와 맥락으로 풀어봅니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                Text("읽기 전용 진단")
                Text("·")
                Text("삭제 자동 실행 없음")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(model.projectRoot.path)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }
}

struct SecurityPrivacyBlock: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("보안/로컬 실행")
                .font(.headline)
            HStack(spacing: 8) {
                StatusBadge(icon: "checkmark.shield.fill", text: "로컬 전용 진단", color: .green)
                StatusBadge(
                    icon: model.virusTotalEnabled ? "network" : "network.slash",
                    text: model.virusTotalEnabled ? "외부 해시 조회 켜짐" : "외부 해시 조회 꺼짐",
                    color: model.virusTotalEnabled ? .orange : .green
                )
            }
            Text(model.virusTotalEnabled
                 ? "VirusTotal이 켜져 있어 파일 내용이 아닌 SHA-256 해시만 외부 조회될 수 있습니다."
                 : "AI/LLM/API 토큰을 쓰지 않고, 기본 검사 결과는 이 Mac 안에서만 생성됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                model.openConfigInFinder()
            } label: {
                Label("설정 파일 확인", systemImage: "gearshape")
            }
        }
        .panelStyle()
    }
}

struct StatusBadge: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
}

struct StatusBlock: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("상태")
                .font(.headline)
            HStack {
                Image(systemName: model.state.symbol)
                    .foregroundStyle(model.state.color)
                Text(model.state.title)
                    .fontWeight(.semibold)
                Spacer()
                if model.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if let summary = model.summary {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary.message)
                        .font(.callout)
                    HStack {
                        CountPill(label: "위험", count: summary.dangerCount, color: .red)
                        CountPill(label: "확인", count: summary.warningCount, color: .orange)
                    }
                }
            } else {
                Text("검사를 실행하면 보안, 자동실행, 네트워크, 저장공간 해석 결과가 여기에 요약됩니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let message = model.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .panelStyle()
    }
}

struct CountPill: View {
    let label: String
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
            Text("\(count)").fontWeight(.bold)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
    }
}

struct ActionBlock: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                model.runScan()
            } label: {
                Label(model.isRunning ? "검사 중..." : "빠른 검사 실행", systemImage: model.isRunning ? "hourglass" : "play.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isRunning)

            HStack {
                Button {
                    model.openNormalReportInBrowser()
                } label: {
                    Label("HTML 열기", systemImage: "safari")
                }
                .disabled(!model.hasNormalReport)

                Button {
                    model.openShareReportInBrowser()
                } label: {
                    Label("공유용", systemImage: "person.crop.circle.badge.checkmark")
                }
                .disabled(!model.hasShareReport)
            }

            Button {
                model.revealReportsInFinder()
            } label: {
                Label("결과 파일 Finder에서 보기", systemImage: "folder")
            }
            .disabled(!model.hasAnyReport)

            Button {
                model.copyCleanupGuide()
            } label: {
                Label("정리 가이드 복사", systemImage: "doc.on.clipboard")
            }
            .disabled(model.storage == nil)
        }
        .panelStyle()
    }
}

struct PermissionBlock: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Full Disk Access")
                .font(.headline)
            if let issues = model.storage?.accessIssues, !issues.isEmpty {
                Label("\(issues.count)개 영역을 읽지 못했을 수 있습니다.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                ForEach(issues.prefix(3)) { issue in
                    Text("\(issue.label): \(issue.note)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else {
                Text("macOS 개인정보 보호 설정 때문에 Mail, Messages, Safari, 앱 컨테이너 일부가 숨겨질 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button {
                    model.openFullDiskAccessSettings()
                } label: {
                    Label("설정 열기", systemImage: "lock.doc")
                }
                Button {
                    model.copyFullDiskAccessGuide()
                } label: {
                    Label("안내 복사", systemImage: "doc.on.doc")
                }
            }
        }
        .panelStyle()
    }
}

struct StorageDecoderBlock: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("저장공간 막대 해석")
                .font(.headline)
            if let storage = model.storage {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(storage.mount)
                            .fontWeight(.semibold)
                        Spacer()
                        Text("\(storage.freeGB, specifier: "%.1f")GB 남음")
                            .foregroundStyle(storage.riskColor)
                    }
                    ProgressView(value: min(max(storage.usePercent, 0), 100), total: 100)
                        .tint(storage.riskColor)
                    Text("사용률 \(Int(storage.usePercent))% · macOS의 System Data/Developer 막대를 실제 경로로 나눠 봅니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                StorageList(title: "System Data 후보", items: storage.cleanupCandidates)
                StorageList(title: "Developer 후보", items: storage.developerToolchains)
            } else {
                Text("검사 후 System Data로 숨을 수 있는 캐시와 Developer 항목의 SDK/시뮬레이터를 분리해서 보여줍니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .panelStyle()
    }
}

struct StorageList: View {
    @EnvironmentObject private var model: ScanModel
    let title: String
    let items: [StorageItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.bold())
            if items.isEmpty {
                Text("표시할 항목이 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items.prefix(4)) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(item.label)
                                .lineLimit(1)
                            Spacer()
                            Text(item.sizeText)
                                .fontWeight(.semibold)
                        }
                        Text(item.action)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button {
                                model.revealStorageItem(item)
                            } label: {
                                Label("Finder", systemImage: "folder")
                            }
                            Button {
                                model.copyGuide(for: item)
                            } label: {
                                Label("가이드 복사", systemImage: "doc.on.clipboard")
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.caption)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

struct LogBlock: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("실행 로그")
                    .font(.headline)
                Spacer()
                Button {
                    model.clearLog()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(model.logText.isEmpty)
                .help("로그 지우기")
            }
            ScrollView {
                Text(model.logText.isEmpty ? "아직 실행 로그가 없습니다." : model.logText)
                    .font(.caption.monospaced())
                    .foregroundStyle(model.logText.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 120, maxHeight: 220)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
        .panelStyle()
    }
}

struct ReportPane: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("디스크 사고 보드")
                    .font(.headline)
                Spacer()
                Button {
                    model.openNormalReportInBrowser()
                } label: {
                    Label("HTML", systemImage: "square.and.arrow.up")
                }
                .disabled(!model.hasNormalReport)
                Button {
                    model.openShareReportInBrowser()
                } label: {
                    Label("공유용", systemImage: "person.crop.circle.badge.checkmark")
                }
                .disabled(!model.hasShareReport)
                Button {
                    model.revealReportsInFinder()
                } label: {
                    Label("Finder", systemImage: "folder")
                }
                .disabled(!model.hasAnyReport)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()

            if model.summary != nil {
                DashboardScrollView()
            } else {
                EmptyDashboardView()
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct EmptyDashboardView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("아직 진단 결과가 없습니다")
                .font(.title3.bold())
            Text("빠른 검사를 실행하면 이 화면에서 바로 결과를 읽을 수 있습니다.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DashboardScrollView: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                IncidentBoard()
                FindingsNativeSection()
                ActivityNativeSection()
            }
            .padding(18)
        }
    }
}

struct IncidentBoard: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let storage = model.storage {
                IncidentHeader(storage: storage)
                LazyVGrid(columns: [
                    GridItem(.flexible(minimum: 220), spacing: 12),
                    GridItem(.flexible(minimum: 220), spacing: 12),
                    GridItem(.flexible(minimum: 220), spacing: 12)
                ], alignment: .leading, spacing: 12) {
                    IncidentLane(
                        title: "지금 회수 가능",
                        subtitle: "\(storage.reclaimableText) 후보",
                        icon: "trash",
                        tint: .orange
                    ) {
                        if storage.cleanupCandidates.isEmpty {
                            EmptyLaneMessage("빠른 검사에서 큰 재생성 캐시를 찾지 못했습니다.")
                        } else {
                            ForEach(Array(storage.cleanupCandidates.prefix(6))) { item in
                                IncidentStorageRow(item: item)
                            }
                        }
                    }

                    IncidentLane(
                        title: "개발 때문에 유지",
                        subtitle: "\(storage.developerText) 규모",
                        icon: "hammer",
                        tint: .blue
                    ) {
                        if storage.developerToolchains.isEmpty {
                            EmptyLaneMessage("SDK, Simulator runtime, toolchain 후보가 없습니다.")
                        } else {
                            ForEach(Array(storage.developerToolchains.prefix(6))) { item in
                                IncidentStorageRow(item: item)
                            }
                        }
                    }

                    IncidentLane(
                        title: "반복 생성원",
                        subtitle: "\(storage.attentionRuntimeSignals.count)개 신호",
                        icon: "arrow.triangle.2.circlepath",
                        tint: .red
                    ) {
                        if storage.attentionRuntimeSignals.isEmpty {
                            EmptyLaneMessage("공간을 다시 채울 실행원 경고가 없습니다.")
                        } else {
                            ForEach(Array(storage.attentionRuntimeSignals.prefix(8))) { signal in
                                RuntimeSignalRow(signal: signal)
                            }
                        }
                    }
                }
            } else {
                Text("저장공간 결과가 아직 없습니다.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct IncidentHeader: View {
    let storage: StorageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("디스크 사고 원인 보드", systemImage: "internaldrive")
                        .font(.title2.bold())
                    Text("macOS가 System Data와 Developer로 숨긴 항목을 실제 경로, 보존 이유, 반복 생성원으로 나눕니다.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text("\(storage.freeGB, specifier: "%.1f")GB 남음")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(storage.riskColor)
                    Text("사용률 \(Int(storage.usePercent))% · \(storage.mount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ProgressView(value: min(max(storage.usePercent, 0), 100), total: 100)
                .tint(storage.riskColor)

            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 140), spacing: 10)
            ], alignment: .leading, spacing: 10) {
                MetricChip(icon: "externaldrive.badge.minus", title: "회수 후보", value: storage.reclaimableText, tint: .orange)
                MetricChip(icon: "wrench.and.screwdriver", title: "개발 보존", value: storage.developerText, tint: .blue)
                MetricChip(icon: "bolt.horizontal.circle", title: "생성원", value: "\(storage.attentionRuntimeSignals.count)개", tint: .red)
                MetricChip(icon: "lock.shield", title: "권한 확인", value: "\(storage.accessIssues.count)개", tint: storage.accessIssues.isEmpty ? .green : .orange)
            }
        }
        .padding(18)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct MetricChip: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.bold())
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct IncidentLane<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let content: Content

    init(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                content
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 330, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct EmptyLaneMessage: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }
}

struct IncidentStorageRow: View {
    @EnvironmentObject private var model: ScanModel
    let item: StorageItem

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            RiskDot(risk: item.risk)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.label)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(item.sizeText)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(item.action)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(item.note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            VStack(spacing: 4) {
                Button {
                    model.revealStorageItem(item)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Finder에서 보기")
                Button {
                    model.copyGuide(for: item)
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.borderless)
                .help("정리 가이드 복사")
            }
        }
        .padding(.vertical, 8)
        Divider()
    }
}

struct RuntimeSignalRow: View {
    let signal: RuntimeSignal

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            RiskDot(risk: signal.risk)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(signal.label)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(signal.countText)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(signal.action)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(signal.note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        Divider()
    }
}

struct VerdictPanel: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        let summary = model.summary
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(verdictColor.opacity(0.14))
                    .frame(width: 62, height: 62)
                Image(systemName: verdictSymbol)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(verdictColor)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(verdictTitle)
                    .font(.title2.bold())
                Text(summary?.message ?? "검사 결과를 읽었습니다.")
                    .foregroundStyle(.secondary)
                HStack {
                    CountPill(label: "위험", count: summary?.dangerCount ?? 0, color: .red)
                    CountPill(label: "확인", count: summary?.warningCount ?? 0, color: .orange)
                    if let storage = model.storage {
                        CountPill(label: "남은 공간", count: Int(storage.freeGB), color: storage.riskColor)
                    }
                }
            }
            Spacer()
        }
        .sectionPanelStyle()
    }

    private var verdictTitle: String {
        switch model.summary?.overall {
        case "danger": return "즉시 확인 필요"
        case "warning": return "정리와 확인 권장"
        case "safe": return "큰 이상 없음"
        default: return "대기 중"
        }
    }

    private var verdictSymbol: String {
        switch model.summary?.overall {
        case "danger": return "exclamationmark.octagon.fill"
        case "warning": return "exclamationmark.triangle.fill"
        case "safe": return "checkmark.shield.fill"
        default: return "circle.dotted"
        }
    }

    private var verdictColor: Color {
        switch model.summary?.overall {
        case "danger": return .red
        case "warning": return .orange
        case "safe": return .green
        default: return .secondary
        }
    }
}

struct StorageNativeSection: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "macOS 저장공간", subtitle: "System Data와 Developer로 뭉친 항목을 실제 경로 기준으로 봅니다.")
            if let storage = model.storage {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(storage.mount)
                                .font(.headline)
                            Spacer()
                            Text("\(storage.freeGB, specifier: "%.1f")GB 남음")
                                .font(.title3.bold())
                                .foregroundStyle(storage.riskColor)
                        }
                        ProgressView(value: min(max(storage.usePercent, 0), 100), total: 100)
                            .tint(storage.riskColor)
                        Text("사용률 \(Int(storage.usePercent))% · 총 \(storage.totalGB, specifier: "%.1f")GB 중 \(storage.usedGB, specifier: "%.1f")GB 사용")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 260)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("바로 볼 후보")
                            .font(.headline)
                        ForEach((storage.cleanupCandidates + storage.developerToolchains).prefix(5)) { item in
                            StorageNativeRow(item: item)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack(alignment: .top, spacing: 18) {
                    StorageNativeList(title: "System Data 후보", items: storage.cleanupCandidates)
                    StorageNativeList(title: "Developer 후보", items: storage.developerToolchains)
                }
            } else {
                Text("저장공간 결과가 아직 없습니다.")
                    .foregroundStyle(.secondary)
            }
        }
        .sectionPanelStyle()
    }
}

struct StorageNativeList: View {
    let title: String
    let items: [StorageItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            if items.isEmpty {
                Text("표시할 항목이 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items.prefix(8)) { item in
                    StorageNativeRow(item: item)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StorageNativeRow: View {
    @EnvironmentObject private var model: ScanModel
    let item: StorageItem

    var body: some View {
        HStack(spacing: 10) {
            RiskDot(risk: item.risk)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.label)
                        .font(.subheadline.weight(.medium))
                    Text(item.sizeText)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                Text(item.action)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                model.revealStorageItem(item)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Finder에서 보기")
            Button {
                model.copyGuide(for: item)
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.borderless)
            .help("정리 가이드 복사")
        }
        .padding(.vertical, 5)
    }
}

struct FindingsNativeSection: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "발견 사항", subtitle: "삭제보다 먼저 확인해야 할 맥락입니다.")
            if model.findings.isEmpty {
                Label("주의가 필요한 항목이 없습니다.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                ForEach(model.findings.prefix(8)) { finding in
                    DiagnosticRow(
                        risk: finding.level,
                        title: finding.title,
                        subtitle: finding.detail,
                        trailing: finding.category
                    )
                }
            }
        }
        .sectionPanelStyle()
    }
}

struct ActivityNativeSection: View {
    @EnvironmentObject private var model: ScanModel
    @State private var tab: ActivityTab = .cpu

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "실행 중인 신호", subtitle: "CPU, 네트워크, 자동실행, 최근 설치 항목을 빠르게 훑습니다.")
                Spacer()
                Picker("보기", selection: $tab) {
                    ForEach(ActivityTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 360)
            }
            activityRows
        }
        .sectionPanelStyle()
    }

    @ViewBuilder
    private var activityRows: some View {
        switch tab {
        case .cpu:
            RowList(rows: model.cpuRows.prefix(12).map {
                DiagnosticDisplayRow(risk: $0.risk, title: $0.name, subtitle: $0.path, trailing: String(format: "%.1f%% CPU", $0.cpu))
            })
        case .network:
            RowList(rows: model.networkRows.prefix(12).map {
                DiagnosticDisplayRow(risk: $0.risk, title: $0.process, subtitle: $0.remoteAddress, trailing: "\($0.remotePort)")
            })
        case .autoruns:
            RowList(rows: model.autorunRows.prefix(12).map {
                DiagnosticDisplayRow(risk: $0.risk, title: $0.entry, subtitle: $0.image, trailing: $0.category)
            })
        case .installs:
            RowList(rows: model.recentInstalls.prefix(12).map {
                DiagnosticDisplayRow(risk: $0.risk, title: $0.name, subtitle: $0.publisher.isEmpty ? $0.note : $0.publisher, trailing: $0.installDate)
            })
        }
    }
}

struct RowList: View {
    let rows: [DiagnosticDisplayRow]

    var body: some View {
        if rows.isEmpty {
            Text("표시할 항목이 없습니다.")
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    DiagnosticRow(risk: row.risk, title: row.title, subtitle: row.subtitle, trailing: row.trailing)
                    if row.id != rows.last?.id {
                        Divider()
                    }
                }
            }
        }
    }
}

struct DiagnosticRow: View {
    let risk: String
    let title: String
    let subtitle: String
    let trailing: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            RiskDot(risk: risk)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? "이름 없음" : title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if !trailing.isEmpty {
                Text(trailing)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 7)
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.title3.bold())
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct RiskDot: View {
    let risk: String

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
    }

    private var color: Color {
        switch risk {
        case "danger": return .red
        case "warning": return .orange
        case "safe": return .green
        case "info": return .blue
        default: return .gray
        }
    }
}

enum ActivityTab: String, CaseIterable, Identifiable {
    case cpu
    case network
    case autoruns
    case installs

    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .network: return "네트워크"
        case .autoruns: return "자동실행"
        case .installs: return "최근 설치"
        }
    }
}

struct DiagnosticDisplayRow: Identifiable {
    let id = UUID()
    let risk: String
    let title: String
    let subtitle: String
    let trailing: String
}
