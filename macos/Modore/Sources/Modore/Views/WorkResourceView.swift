import SwiftUI

struct WorkResourceView: View {
    @EnvironmentObject private var model: ScanModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = WorkResourceService()
    @State private var filter = "active"
    @State private var detail: WorkResource?
    @State private var connecting: WorkResource?
    @State private var pending: WorkResource?
    @State private var pendingAction = ""
    @State private var showIdle = false
    @State private var showReceipt = false
    @State private var knownWorkspaces: [String] = []
    @State private var projectAssignments: [String: [String]] = [:]

    private var resources: [WorkResource] { service.snapshot?.resources ?? [] }
    private var projects: [String] { Array(Set(resources.flatMap(projectsFor))).sorted() }
    private func projectsFor(_ r: WorkResource) -> [String] {
        projectAssignments[r.id] ?? []
    }

    private var selected: [WorkResource] {
        resources.filter { r in
            switch filter {
            case "active": return r.isRunning
            case "all": return true
            case "simulator", "volume": return r.kind == filter
            default: return projectsFor(r).contains(filter)
            }
        }.sorted { a, b in
            if a.isRunning != b.isRunning { return a.isRunning }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
    private var title: String {
        switch filter {
        case "active": return "사용 중인 환경"
        case "all": return "모든 환경"
        case "simulator": return "시뮬레이터"
        case "volume": return "외장 드라이브"
        default: return URL(fileURLWithPath: filter).lastPathComponent
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up").font(.title2).foregroundStyle(.blue)
                Text("작업 환경").font(.title2.weight(.semibold))
                Spacer()
                if service.busy { ProgressView().controlSize(.small) }
                if let snap = service.snapshot {
                    Text(Date(timeIntervalSince1970: snap.observedAt), style: .time).font(.caption).foregroundStyle(.secondary)
                }
                Button { Task { await service.refresh(root: model.projectRoot) } } label: { Image(systemName: "arrow.clockwise") }
                    .help("상태 새로고침").disabled(service.busy)
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 205)
                Divider()
                mainContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 1000, height: 720)
        .onAppear { updateWorkspaces() }
        .onChange(of: model.sessionIndex) { _ in updateWorkspaces() }
        .onChange(of: service.snapshot?.observedAt) { _ in updateAssignments() }
        .task {
            while !Task.isCancelled {
                await service.refresh(root: model.projectRoot)
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            }
        }
        .sheet(item: $detail) { r in ResourceDetailSheet(resource: resources.first { $0.id == r.id } ?? r) }
        .sheet(item: $connecting) { r in
            ResourceConnectionSheet(resource: r, sessions: model.sessionIndex?.sessions ?? []) { project, session in
                act(r, "claim", project: project, session: session)
            }
        }
        .alert(pendingAction == "delete-duplicate" ? "중복 기기를 삭제할까요?" : "연결된 작업에 영향을 줍니다", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("취소", role: .cancel) { pending = nil }
            Button(pendingAction == "delete-duplicate" ? "영구 삭제" : "계속 실행", role: .destructive) {
                if let r = pending { act(r, pendingAction, override: true) }; pending = nil
            }
        } message: {
            Text(pendingAction == "delete-duplicate" ? "\(pending?.name ?? "")의 내부 앱과 데이터가 삭제됩니다. 같은 OS·기종의 다른 기기는 남습니다." : "\(pending?.name ?? "")에 연결된 세션 \(pending?.leases.count ?? 0)개가 있습니다. 확인 후 계속할 수 있습니다.")
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            nav("사용 중", icon: "bolt.circle", key: "active", count: resources.filter(\.isRunning).count)
            nav("전체", icon: "square.grid.2x2", key: "all", count: resources.count)
            Divider().padding(.vertical, 10)
            Text("기기").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10)
            nav("시뮬레이터", icon: "iphone", key: "simulator", count: resources.filter { $0.kind == "simulator" }.count)
            nav("외장 드라이브", icon: "externaldrive", key: "volume", count: resources.filter { $0.kind == "volume" }.count)
            Divider().padding(.vertical, 10)
            Text("연결된 프로젝트").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10)
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(projects, id: \.self) { p in
                        nav(URL(fileURLWithPath: p).lastPathComponent, icon: "folder", key: p, count: resources.filter { projectsFor($0).contains(p) }.count)
                    }
                    if projects.isEmpty { Text("연결을 확인하면\n프로젝트가 여기에 표시됩니다.").font(.caption).foregroundStyle(.secondary).padding(10) }
                }
            }
            Text("10초마다 자동 갱신").font(.caption).foregroundStyle(.secondary).padding(10)
        }.padding(12).frame(maxHeight: .infinity, alignment: .top).background(.regularMaterial)
    }
    private func nav(_ label: String, icon: String, key: String, count: Int) -> some View {
        Button { filter = key; showIdle = false } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).frame(width: 18)
                Text(label).lineLimit(1)
                Spacer(minLength: 2)
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.horizontal, 10).padding(.vertical, 9)
                .background(filter == key ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 25, weight: .semibold))
                    Text("기기 상태와 연결된 작업을 확인하고 관리하세요.").foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    ResourceSummaryTile(title: "실행 중", value: resources.filter { $0.kind == "simulator" && $0.isRunning }.count, icon: "iphone", color: .green)
                    ResourceSummaryTile(title: "연결된 드라이브", value: resources.filter { $0.kind == "volume" }.count, icon: "externaldrive", color: .blue)
                    ResourceSummaryTile(title: "대기 중인 기기", value: resources.filter { !$0.isRunning }.count, icon: "moon", color: .secondary)
                }
                if service.snapshot == nil {
                    HStack {
                        if service.busy { ProgressView() }
                        Text(service.busy ? "연결된 환경을 확인하고 있습니다…" : "환경을 불러오지 못했습니다. 새로고침으로 다시 확인하세요.").foregroundStyle(.secondary)
                    }.padding(.vertical, 35)
                } else if selected.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.secondary)
                        Text("표시할 환경이 없습니다").font(.headline)
                        Text("왼쪽에서 전체 기기를 확인할 수 있습니다.").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 40)
                } else {
                    VStack(spacing: 12) {
                        ForEach(selected) { r in resourceCard(r) }
                    }
                }
                if filter == "active", resources.contains(where: { !$0.isRunning }) {
                    DisclosureGroup("대기 중인 시뮬레이터 \(resources.filter { !$0.isRunning }.count)대", isExpanded: $showIdle) {
                        VStack(spacing: 12) { ForEach(resources.filter { !$0.isRunning }) { r in resourceCard(r) } }.padding(.top, 12)
                    }.foregroundStyle(.secondary)
                }
                if let snap = service.snapshot, !snap.warnings.isEmpty {
                    Label("일부 상태를 확인하지 못했습니다", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    DisclosureGroup("확인할 내용") { ForEach(snap.warnings, id: \.self) { Text($0).font(.caption).textSelection(.enabled) } }
                }
                if !service.message.isEmpty {
                    DisclosureGroup(service.message.hasPrefix("succeeded") ? "요청을 처리했습니다" : "최근 실행 결과", isExpanded: $showReceipt) {
                        Text(service.message).font(.callout).textSelection(.enabled).padding(.top, 8)
                    }.padding(14).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }
            }.padding(26)
        }
    }
    private func resourceCard(_ r: WorkResource) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: r.resourceIcon).font(.system(size: 27, weight: .light))
                    .foregroundStyle(r.kind == "volume" ? Color.blue : Color.primary)
                    .frame(width: 48, height: 48).background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text(r.name).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                    Text(r.kind == "volume" ? "외장 드라이브" : r.runtimeLabel).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text(r.statusLabel).font(.caption.weight(.medium)).padding(.horizontal, 9).padding(.vertical, 5)
                    .background((r.isRunning ? Color.green : Color.secondary).opacity(0.1), in: Capsule())
                    .foregroundStyle(r.isRunning ? Color.green : Color.secondary)
                Menu {
                    Button("프로젝트에 연결…") { connecting = r }
                    Button("상세 정보…") { detail = r }
                    if r.kind == "simulator" {
                        Button("공용 기기로 지정") { act(r, "prefer") }
                        if !r.duplicates.isEmpty { Button("중복 기기 삭제…", role: .destructive) { pendingAction = "delete-duplicate"; pending = r }.disabled(r.state != "Shutdown") }
                    }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().help("기기 관리")
            }
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    let paths = projectsFor(r)
                    if !paths.isEmpty {
                        Label(paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: " · "), systemImage: "folder")
                            .font(.callout).lineLimit(2)
                        Text(r.leases.isEmpty ? "프로젝트의 프로세스가 사용 중" : "연결된 세션 \(r.leases.count)개").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(r.preferred ? "공용으로 재사용하는 기기" : "연결된 프로젝트 미확인").font(.callout).foregroundStyle(.secondary)
                    }
                    if r.kind == "volume", !r.processes.isEmpty {
                        Text("\(r.processes.count)개 프로세스가 사용 중").font(.caption).foregroundStyle(.secondary)
                    }
                    if !r.duplicates.isEmpty { Text("같은 OS·기종의 기기가 \(r.duplicates.count + 1)대 있습니다").font(.caption).foregroundStyle(.orange) }
                }
                Spacer()
                Button("상세 보기") { detail = r }.buttonStyle(.borderless)
                Button(r.kind == "volume" ? "추출" : (r.isRunning ? "종료" : "시작")) {
                    let action = r.kind == "volume" ? "eject" : (r.isRunning ? "shutdown" : "boot")
                    if !r.leases.isEmpty && action != "boot" { pendingAction = action; pending = r }
                    else { act(r, action) }
                }.buttonStyle(.bordered).disabled(service.busy || model.cleanupInFlight || !r.available)
            }
        }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
    private func updateWorkspaces() {
        let genericRoots: Set<String> = ["/", "/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp", "/Users", "/Volumes", NSHomeDirectory(), NSHomeDirectory() + "/Library", NSHomeDirectory() + "/IdeaProjects"]
        knownWorkspaces = Array(Set((model.sessionIndex?.sessions ?? []).map(\.workspace).filter {
            !$0.isEmpty && !genericRoots.contains($0) && !$0.contains("/CoreSimulator/Devices/")
        })).sorted { $0.count > $1.count }
        updateAssignments()
    }
    private func updateAssignments() {
        var assignments: [String: [String]] = [:]
        var cwdProjects: [String: String] = [:]
        let paths = Set(resources.flatMap { $0.processes.map(\.cwd) }.filter { !$0.isEmpty && $0 != "/" })
        for path in paths {
            if let project = knownWorkspaces.first(where: { path == $0 || path.hasPrefix($0 + "/") }) { cwdProjects[path] = project }
        }
        for r in resources {
            assignments[r.id] = Array(Set(r.leases.map(\.project) + r.processes.compactMap { cwdProjects[$0.cwd] })).sorted()
        }
        projectAssignments = assignments
    }
    private func act(_ r: WorkResource, _ action: String, project: String = "", session: String = "", override: Bool = false) {
        let request: [String: Any] = ["action": action, "id": r.id, "fingerprint": r.fingerprint, "project": project, "session": session, "override": override]
        Task { await service.act(model: model, request: request) }
    }
}
