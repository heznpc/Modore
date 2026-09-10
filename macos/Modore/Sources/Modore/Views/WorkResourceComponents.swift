import SwiftUI

extension WorkResource {
    var isRunning: Bool { state == "Booted" || state == "Booting" || state == "Mounted" }
    var statusLabel: String {
        if !available { return L10n.text("사용 불가") }
        switch state { case "Booted": return L10n.text("실행 중"); case "Booting": return L10n.text("시작 중"); case "Mounted": return L10n.text("연결됨"); case "Shutdown": return L10n.text("대기"); default: return state }
    }
    var runtimeLabel: String {
        runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
            .replacingOccurrences(of: "iOS-", with: "iOS ").replacingOccurrences(of: "watchOS-", with: "watchOS ").replacingOccurrences(of: "-", with: ".")
    }
    var resourceIcon: String {
        if kind == "volume" { return "externaldrive" }
        if deviceType.lowercased().contains("ipad") { return "ipad" }
        if deviceType.lowercased().contains("watch") { return "applewatch" }
        return "iphone"
    }
}

struct ResourceSummaryTile: View {
    let title: String
    let value: Int
    let icon: String
    let color: Color
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(value)").font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(16).frame(maxWidth: .infinity).background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
    }
}

struct ResourceDetailSheet: View {
    let resource: WorkResource
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: resource.resourceIcon).font(.title)
                VStack(alignment: .leading) {
                    Text(resource.name).font(.title2.weight(.semibold))
                    Text(resource.statusLabel).foregroundStyle(.secondary)
                }
                Spacer(); Button(L10n.text("닫기")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !resource.leases.isEmpty {
                        Text(L10n.text("연결된 작업")).font(.headline)
                        ForEach(resource.leases) { lease in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(URL(fileURLWithPath: lease.project).lastPathComponent).font(.headline)
                                Text(lease.project).font(.caption).textSelection(.enabled)
                                Text(lease.session).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                    if !resource.processes.isEmpty {
                        Text(L10n.format("사용 중인 프로세스 · %@", String(describing: resource.processes.count))).font(.headline)
                        Text(L10n.text("열린 파일을 기준으로 확인했습니다. 프로젝트 경로가 같아도 특정 세션의 소유로 단정하지 않습니다.")).font(.callout).foregroundStyle(.secondary)
                        ForEach(resource.processes) { p in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(p.name).font(.callout.weight(.medium))
                                    if p.cwd != "/" { Text(p.cwd).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                }
                                Spacer(); Text("PID \(p.pid)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                            Divider()
                        }
                    }
                    DisclosureGroup(L10n.text("기기 식별 정보")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(resource.id).textSelection(.enabled)
                            Text(resource.path).textSelection(.enabled)
                            if !resource.runtime.isEmpty { Text(resource.runtime).textSelection(.enabled) }
                        }.font(.caption.monospaced()).padding(.top, 8)
                    }
                    if !resource.expiredLeases.isEmpty {
                        DisclosureGroup(L10n.format("갱신이 끊긴 연결 %@개", String(describing: resource.expiredLeases.count))) {
                            ForEach(resource.expiredLeases) { lease in Text("\(lease.project) · \(lease.session)").font(.caption).textSelection(.enabled) }
                        }
                    }
                }
            }
        }.padding(24).frame(width: 620, height: 560)
    }
}

struct ResourceConnectionSheet: View {
    let resource: WorkResource
    let sessions: [SessionIndexEntry]
    let connect: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selected: String?
    private var candidates: [SessionIndexEntry] {
        sessions.filter { !$0.workspace.isEmpty && $0.providerSessionId != nil && (search.isEmpty || $0.displayLabel.localizedCaseInsensitiveContains(search) || $0.tool.localizedCaseInsensitiveContains(search)) }.prefix(60).map { $0 }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("프로젝트에 연결")).font(.title2.weight(.semibold))
            Text(L10n.format("%@을 사용하는 작업을 선택하세요.", String(describing: resource.name))).foregroundStyle(.secondary)
            TextField(L10n.text("프로젝트 검색"), text: $search).textFieldStyle(.roundedBorder)
            List(candidates, selection: $selected) { entry in
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.displayLabel).font(.headline)
                        Text("\(entry.tool) · \(entry.lastActive)").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 5).tag(entry.id)
            }
            HStack {
                Text(L10n.text("최근 세션 중 최대 60개 표시")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("취소")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("연결")) {
                    if let entry = candidates.first(where: { $0.id == selected }) { connect(entry.workspace, entry.id); dismiss() }
                }.buttonStyle(.borderedProminent).disabled(selected == nil)
            }
        }.padding(24).frame(width: 540, height: 520)
    }
}
