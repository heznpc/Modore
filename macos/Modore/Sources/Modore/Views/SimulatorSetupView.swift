import SwiftUI

private struct SimulatorSetupOptions: Decodable {
    struct Device: Decodable, Identifiable { let id, name, platform: String }
    struct Runtime: Decodable, Identifiable { let id, name: String; let devices: [Device] }
    let runtimes: [Runtime]
}
struct SimulatorSetupView: View {
    @EnvironmentObject private var model: ScanModel
    @Environment(\.dismiss) private var dismiss
    @State private var options: SimulatorSetupOptions?
    @State private var runtime = ""
    @State private var device = ""
    @State private var platform = "iOS"
    @State private var version = ""
    @State private var busy = false
    @State private var message = ""
    @State private var downloadConfirm = false
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack { Text("필요한 시뮬레이터 준비").font(.title2.bold());Spacer();Button("닫기") { dismiss() }.disabled(busy) }
            Text("OS와 기종을 직접 선택하세요. 같은 OS·기종이 이미 있으면 새로 만들지 않고 재사용합니다.").foregroundStyle(.secondary)
            GroupBox("설치된 OS에서 기기 준비") {
                VStack(alignment:.leading,spacing:12) {
                    Picker("OS",selection:$runtime) { Text("선택").tag("");ForEach(options?.runtimes ?? []) { Text($0.name).tag($0.id) } }
                    Picker("기종",selection:$device) {
                        Text("선택").tag("")
                        ForEach(options?.runtimes.first { $0.id==runtime }?.devices ?? []) { Text("\($0.platform) · \($0.name)").tag($0.id) }
                    }
                    Button("기존 기기 재사용 · 없으면 생성") { perform(["action":"ensure-device","runtime":runtime,"deviceType":device]) }.disabled(runtime.isEmpty || device.isEmpty || busy)
                }.padding(10)
            }
            GroupBox("없는 OS 설치") {
                VStack(alignment:.leading,spacing:12) {
                    Picker("플랫폼",selection:$platform) { Text("iOS / iPadOS").tag("iOS");Text("watchOS").tag("watchOS") }
                    TextField("OS 버전 (예: 26.5)",text:$version)
                    Text("Apple에서 런타임을 다운로드합니다. 수 GB 이상의 공간과 시간이 필요하며, 설치 후 위에서 기종을 선택합니다.").font(.caption).foregroundStyle(.secondary)
                    Button("OS 다운로드·설치…") { downloadConfirm=true }.disabled(version.isEmpty || busy)
                }.padding(10)
            }
            if busy { ProgressView("처리 중 · 다운로드는 오래 걸릴 수 있습니다") }
            if !message.isEmpty { Text(message).textSelection(.enabled) }
            Spacer()
        }.padding(24).frame(width:640,height:560).interactiveDismissDisabled(busy)
        .task { await load() }
        .onChange(of:runtime) { _ in device="" }
        .confirmationDialog("\(platform) \(version)을 다운로드하고 설치할까요?",isPresented:$downloadConfirm,titleVisibility:.visible) {
            Button("다운로드·설치") { perform(["action":"download-runtime","platform":platform,"version":version]) }
            Button("취소",role:.cancel) {}
        }
    }
    private func load() async {
        do {options=try JSONDecoder().decode(SimulatorSetupOptions.self,from:await EnvironmentRetirementService.invoke(root:model.projectRoot,request:["action":"setup-options"]))}
        catch {message=error.localizedDescription}
    }
    private func perform(_ request:[String:Any]) {
        guard !busy,!model.cleanupInFlight,!model.applicationTerminationStarted else {return}
        busy=true;model.cleanupInFlight=true;model.beginDestructiveCleanupTransaction()
        Task {
            defer {busy=false;model.cleanupInFlight=false;model.finishDestructiveCleanupTransaction()}
            do {
                let data=try await EnvironmentRetirementService.invoke(root:model.projectRoot,request:request)
                let result=try JSONSerialization.jsonObject(with:data) as? [String:Any]
                message=result?["message"] as? String ?? "처리 결과 확인 필요"
                await load()
            } catch {message=error.localizedDescription}
        }
    }
}
