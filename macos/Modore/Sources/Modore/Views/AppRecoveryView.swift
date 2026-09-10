import AppKit
import SwiftUI

private struct RestartableApp: Identifiable {
    let id: Int32
    let name: String
    let url: URL
    let launched: Date?
    let identity: FilesystemIdentity
}
struct AppRecoveryView: View {
    @EnvironmentObject private var model: ScanModel
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [RestartableApp] = []
    @State private var selected: RestartableApp?
    @State private var busy = false
    @State private var message = ""
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack { Text("앱만 다시 시작").font(.title2.bold());Spacer();Button("닫기") { dismiss() }.disabled(busy) }
            Text("Mac을 재부팅하지 않고 선택한 앱만 정상 종료한 뒤 다시 엽니다. 저장 요청이 나오면 앱에서 먼저 처리하세요.").foregroundStyle(.secondary)
            List(apps) { app in
                HStack { Text(app.name);Spacer();Button("재시작…") { selected=app }.disabled(busy) }
            }
            if busy { ProgressView("앱의 정상 종료와 재실행을 확인하고 있습니다…") }
            if !message.isEmpty { Text(message).textSelection(.enabled) }
        }.padding(22).frame(width:600,height:520).interactiveDismissDisabled(busy)
        .onAppear { refresh() }
        .confirmationDialog("\(selected?.name ?? "앱")을 다시 시작할까요?",isPresented:Binding(get:{selected != nil},set:{if !$0 {selected=nil}}),titleVisibility:.visible) {
            Button("정상 종료 후 다시 열기") { if let app=selected { Task { await restart(app) } };selected=nil }
            Button("취소",role:.cancel) { selected=nil }
        } message: { Text("진행 중인 작업이 중단될 수 있습니다. 앱이 저장 확인 등으로 종료하지 않으면 강제 종료하지 않고 기다림을 끝냅니다.") }
    }
    private func refresh() {
        apps=NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let url=app.bundleURL, let identity=FilesystemIdentity.directory(at:url) else {return nil}
            return RestartableApp(id:app.processIdentifier,name:app.localizedName ?? url.lastPathComponent,url:url,launched:app.launchDate,identity:identity)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
