import AppKit
import SwiftUI

private struct RestartableApp: Identifiable {
    let id: Int32
    let name: String
    let url: URL
    let launched: Date?
    let identity: FilesystemIdentity
    let icon: NSImage?
    let memory: UInt64?
}
struct AppRecoveryView: View {
    @EnvironmentObject private var model: ScanModel
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [RestartableApp] = []
    @EnvironmentObject private var monitor: CPUWatchService
    @State private var highlighted: Int32?
    @State private var selected: RestartableApp?
    @State private var busy = false
    @State private var message = ""
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            HStack {
                VStack(alignment:.leading,spacing:6) {
                    Text("실행 중인 앱").font(.system(size:30,weight:.bold))
                    Text("앱을 선택해 작업을 확인하고 다시 시작하세요.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("새로 고침") { refresh() }.disabled(busy)
            }
            HStack(alignment:.top,spacing:24) {
                ScrollView {
                    LazyVStack(spacing:8) {
                        ForEach(apps) { app in
                            Button { highlighted=app.id } label: {
                                HStack(spacing:14) {
                                    appIcon(app).frame(width:36,height:36)
                                    Text(app.name).font(.headline)
                                    Spacer()
                                    Text(memoryLabel(app)).monospacedDigit().foregroundStyle(.secondary)
                                }.padding(14).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .background(highlighted == app.id ? Color.teal.opacity(0.12) : Color.secondary.opacity(0.04),in:RoundedRectangle(cornerRadius:12))
                        }
                    }
                }.frame(maxWidth:.infinity)
                VStack(spacing:18) {
                    if let app=apps.first(where:{$0.id == highlighted}) {
                        appIcon(app).frame(width:72,height:72)
                        Text(app.name).font(.title2.bold())
                        Label(memoryLabel(app),systemImage:"memorychip").foregroundStyle(.secondary)
                        Button { focus(app) } label: { Label("앱 앞으로 가져오기",systemImage:"arrow.up.forward.app").frame(maxWidth:.infinity).padding(8) }.buttonStyle(.borderedProminent).tint(.teal).disabled(busy)
                        Button { selected=app } label: { Label("종료 후 다시 열기…",systemImage:"arrow.clockwise").frame(maxWidth:.infinity).padding(8) }.buttonStyle(.bordered).disabled(busy)
                        Text("저장 요청이 나오면 앱에서 처리하세요.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Image(systemName:"app.dashed").font(.system(size:52)).foregroundStyle(.teal)
                        Text("앱 선택").font(.title2.bold())
                        Text("왼쪽에서 확인할 앱을 선택하세요.").foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(22).frame(width:280).frame(maxHeight:.infinity).background(Color.teal.opacity(0.035),in:RoundedRectangle(cornerRadius:20))
            }
            if busy { ProgressView("앱의 정상 종료와 재실행을 확인하고 있습니다…") }
            if !message.isEmpty { Text(message).textSelection(.enabled) }
            Text("메모리는 측정된 프로세스의 상주량입니다. 미측정 앱과 별도 보조 프로세스는 합산하지 않습니다.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity).interactiveDismissDisabled(busy)
        .onAppear { refresh() }
        .confirmationDialog("\(selected?.name ?? "앱")을 다시 시작할까요?",isPresented:Binding(get:{selected != nil},set:{if !$0 {selected=nil}}),titleVisibility:.visible) {
            Button("정상 종료 후 다시 열기") { if let app=selected { Task { await restart(app) } };selected=nil }
            Button("취소",role:.cancel) { selected=nil }
        } message: { Text("진행 중인 작업이 중단될 수 있습니다. 앱이 저장 확인 등으로 종료하지 않으면 강제 종료하지 않고 기다림을 끝냅니다.") }
    }
    @ViewBuilder private func appIcon(_ app:RestartableApp) -> some View {
        if let icon=app.icon { Image(nsImage:icon).resizable().scaledToFit() }
        else { Image(systemName:"app").resizable().scaledToFit().foregroundStyle(.teal) }
    }
    private func memoryLabel(_ app:RestartableApp) -> String {
        app.memory.map { ByteCountFormatter.string(fromByteCount:Int64(clamping:$0),countStyle:.memory) } ?? "미측정"
    }
    private func focus(_ item:RestartableApp) {
        guard let app=NSRunningApplication(processIdentifier:item.id),app.launchDate==item.launched,app.bundleURL==item.url else {message="앱 상태가 바뀌었습니다. 다시 확인하세요.";refresh();return}
        if !app.activate(options:[.activateIgnoringOtherApps]) { message="앱을 앞으로 가져오지 못했습니다." }
    }
    private func refresh() {
        apps=NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let url=app.bundleURL, let identity=FilesystemIdentity.directory(at:url) else {return nil}
            return RestartableApp(id:app.processIdentifier,name:app.localizedName ?? url.lastPathComponent,url:url,launched:app.launchDate,identity:identity,icon:app.icon,memory:monitor.snapshot?.processes.first(where:{$0.pid == app.processIdentifier})?.residentBytes)
        }.sorted { if $0.memory != $1.memory { return ($0.memory ?? 0) > ($1.memory ?? 0) }; return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private func restart(_ item:RestartableApp) async {
        guard !busy,!model.cleanupInFlight,!model.applicationTerminationStarted else {return}
        busy=true;model.cleanupInFlight=true;model.beginDestructiveCleanupTransaction()
        defer {busy=false;model.cleanupInFlight=false;model.finishDestructiveCleanupTransaction();refresh()}
        var receipt:[String:Any]=["action":"app-restart","name":item.name,"pid":item.id,"bundle":item.url.path,"startedAt":Date().timeIntervalSince1970,"mutation":"pending","verification":"pending"]
        let root=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Modore/environment-retirement")
        let record=root.appendingPathComponent("app-restart-\(UUID().uuidString).json")
        func save() throws { try SecureLocalFileIO.atomicWrite(JSONSerialization.data(withJSONObject:receipt),to:record,permissions:0o600) }
        do {
            guard let app=NSRunningApplication(processIdentifier:item.id), app.launchDate==item.launched,
                  app.bundleURL==item.url, FilesystemIdentity.directory(at:item.url)==item.identity else {throw RetirementError("앱의 대상 상태가 바뀌었습니다. 목록을 다시 확인하세요.")}
            let before=try await EnvironmentRetirementService.invoke(root:model.projectRoot,request:["action":"health"])
            receipt["before"]=try JSONSerialization.jsonObject(with:before)
            receipt["mutation"]="attempting";try save()
            guard app.terminate() else {throw RetirementError("앱이 정상 종료 요청을 받지 못했습니다.")}
            for _ in 0..<60 {
                if app.isTerminated {break}
                try await Task.sleep(nanoseconds:500_000_000)
            }
            guard app.isTerminated else {throw RetirementError("앱이 아직 열려 있습니다. 저장 요청을 처리한 뒤 다시 시도하세요. 강제 종료하지 않았습니다.")}
            guard FilesystemIdentity.directory(at:item.url)==item.identity else {throw RetirementError("종료 후 앱 파일이 바뀌어 재실행하지 않았습니다.")}
            let launched: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
                NSWorkspace.shared.openApplication(at:item.url,configuration:NSWorkspace.OpenConfiguration()) { app,error in
                    if let app {continuation.resume(returning:app)}
                    else {continuation.resume(throwing:error ?? RetirementError("앱 재실행 응답 없음"))}
                }
            }
            receipt["mutation"]="succeeded"
            receipt["verification"]=(!launched.isTerminated && launched.bundleURL==item.url) ? "verified":"pending"
            receipt["newPID"]=launched.processIdentifier
            let after=try await EnvironmentRetirementService.invoke(root:model.projectRoot,request:["action":"health"])
            receipt["after"]=try JSONSerialization.jsonObject(with:after)
            message="\(item.name)을 다시 열었습니다. 메모리·디스크 전후 상태를 기록했습니다."
        } catch {receipt["error"]=error.localizedDescription;message=error.localizedDescription}
        receipt["finishedAt"]=Date().timeIntervalSince1970
        do {try save()} catch {message += "\n기록 저장 실패: \(error.localizedDescription)"}
    }
}
