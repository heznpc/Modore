import SwiftUI
struct WorkResourceView: View {
    @EnvironmentObject private var model: ScanModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = WorkResourceService()
    @State private var layer = "all"
    @State private var project = ""
    @State private var session = ""
    @State private var override = false
    @State private var projectOnly = false
    @State private var pending: WorkResource?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("작업 환경 제어").font(.title2.bold())
                Spacer()
                if service.busy { ProgressView().controlSize(.small) }
                Button("새로고침") { Task { await service.refresh(root: model.projectRoot) } }.disabled(service.busy)
                Button("닫기") { dismiss() }
            }
            Picker("레이어", selection: $layer) {
                Text("전체").tag("all"); Text("시뮬레이터").tag("simulator"); Text("외장 SSD").tag("volume")
            }.pickerStyle(.segmented)
            Menu("최근 프로젝트·세션에서 선택") {
                ForEach(Array((model.sessionIndex?.sessions ?? []).filter { !$0.workspace.isEmpty && $0.providerSessionId != nil }.prefix(40))) { entry in
                    Button("\(entry.displayLabel) · \(entry.tool) · \(entry.lastActive)") {
                        project = entry.workspace
                        session = entry.id
                    }
                }
            }
            HStack {
                TextField("프로젝트 절대 경로", text: $project)
                TextField("세션 ID", text: $session)
            }
            Toggle("입력한 프로젝트 레이어만 보기", isOn: $projectOnly)
            Toggle("연결된 세션에 영향을 줄 수 있다는 경고를 확인하고 실행", isOn: $override)
            if let snap = service.snapshot {
                Text("\(Date(timeIntervalSince1970: snap.observedAt).formatted(date: .omitted, time: .standard)) 관찰 · 10초마다 갱신").font(.caption)
                Text(snap.coverage).font(.caption).foregroundStyle(.secondary)
                ForEach(snap.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                List(snap.resources.filter { (layer == "all" || $0.kind == layer) && (!projectOnly || $0.leases.contains { $0.project == project } || $0.processes.contains { $0.cwd == project || $0.cwd.hasPrefix(project + "/") }) }) { r in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(r.name).font(.headline)
                            Text(r.state).foregroundStyle(r.state == "Booted" ? .green : .secondary)
                            if r.preferred { Text("공용 재사용").foregroundStyle(.blue) }
                            if !r.duplicates.isEmpty { Text("동일 OS·기종 \(r.duplicates.count + 1)대").foregroundStyle(.orange) }
                        }
                        Text(r.runtime.isEmpty ? r.path : r.runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "") + " · " + r.id).font(.caption).textSelection(.enabled)
                        if r.leases.isEmpty { Text("등록된 사용 세션 없음 · 미사용을 뜻하지 않습니다").font(.caption).foregroundStyle(.secondary) }
                        ForEach(r.leases) { lease in
                            Text("연결: \(lease.project) · \(lease.session)").font(.caption).textSelection(.enabled)
                        }
                        if !r.expiredLeases.isEmpty { Text("갱신이 끊긴 과거 연결 \(r.expiredLeases.count)건").font(.caption).foregroundStyle(.secondary) }
                        ForEach(r.processes.prefix(12)) { p in
                            Text("점유 관찰: \(p.name) [\(p.pid)] \(p.cwd)").font(.caption).textSelection(.enabled)
                        }
                        if r.processes.count > 12 { Text("추가 점유 프로세스 \(r.processes.count - 12)개").font(.caption) }
                        HStack {
                            Button("이 작업에 연결") { act(r, "claim") }.disabled(project.isEmpty || session.isEmpty)
                            if r.kind == "simulator" {
                                Button("공용으로 지정") { act(r, "prefer") }
                                Button(r.state == "Booted" ? "종료" : "시작") { act(r, r.state == "Booted" ? "shutdown" : "boot") }
                                if !r.duplicates.isEmpty { Button("중복 기기 삭제…", role: .destructive) { pending = r }.disabled(r.state != "Shutdown") }
                            } else { Button("SSD 추출") { act(r, "eject") } }
                        }.buttonStyle(.borderless).disabled(service.busy || model.cleanupInFlight)
                    }.padding(.vertical, 6)
                }
            }
            Text(service.message).font(.caption).textSelection(.enabled)
        }.padding(18).frame(minWidth: 850, minHeight: 650)
        .task {
            while !Task.isCancelled {
                await service.refresh(root: model.projectRoot)
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            }
        }
        .alert("중복 시뮬레이터를 영구 삭제할까요?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("취소", role: .cancel) { pending = nil }
            Button("기기와 내부 앱 데이터 삭제", role: .destructive) {
                if let r = pending { act(r, "delete-duplicate") }; pending = nil
            }
        } message: { Text("\(pending?.name ?? "") · \(pending?.id ?? "")\n같은 OS·기종의 다른 기기는 남습니다. 삭제한 기기의 데이터는 되돌릴 수 없습니다.") }
    }
    private func act(_ r: WorkResource, _ action: String) {
        let request: [String: Any] = ["action": action, "id": r.id, "fingerprint": r.fingerprint,
                                      "project": project, "session": session, "override": override]
        Task { await service.act(model: model, request: request) }
    }
}
