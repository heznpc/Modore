import AppKit
import SwiftUI

struct ResourceFocusView: View {
    @EnvironmentObject private var model: ScanModel
    @Environment(\.dismiss) private var dismiss
    let item: EnvironmentItem
    let planID: String?
    @State private var apps:[NSRunningApplication] = []
    @State private var message = "대상 확인 중"
    private var sessions:[SessionIndexEntry] { (model.sessionIndex?.sessions ?? []).filter { !$0.workspace.isEmpty && $0.workspace == item.project } }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack { Label(item.name,systemImage:item.icon).font(.title2.bold());Spacer();Button("닫기") { dismiss() } }
            Text(message).font(.callout).foregroundStyle(.secondary)
            ForEach(apps,id:\.processIdentifier) { app in
                Button {
                    if !app.activate(options:[.activateIgnoringOtherApps]) {message="앱을 앞으로 가져오지 못했습니다."}
                } label: { HStack { Text(app.localizedName ?? "연결 앱"); Spacer(); Label("앱 앞으로",systemImage:"arrow.up.forward.app") }.padding(16).contentShape(Rectangle()) }.buttonStyle(.plain).background(Color.teal.opacity(0.08),in:RoundedRectangle(cornerRadius:12))
            }
            if !item.path.isEmpty { Button("대상 위치 보기") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:item.path)]) } }
            Text("같은 프로젝트의 대화 · 실행 주체로 확정된 연결은 아닙니다").font(.headline)
            ScrollView {
                VStack(spacing:10) {
                    ForEach(sessions) { session in
                        Button {
                            if session.tool.lowercased()=="codex",let id=session.providerSessionId,UUID(uuidString:id) != nil,let url=URL(string:"codex://threads/"+id) { NSWorkspace.shared.open(url) }
                            else { NSWorkspace.shared.activateFileViewerSelecting([session.sourceURL]) }
                        } label: {
                            HStack { VStack(alignment:.leading,spacing:5) { Text(session.tool + " · " + session.displayLabel); Text(session.lastActive).font(.caption).foregroundStyle(.secondary) };Spacer();Text(session.tool.lowercased()=="codex" ? "대화 열기" : "대화 파일 보기").foregroundStyle(.teal) }.padding(14).contentShape(Rectangle())
                        }.buttonStyle(.plain).background(Color.secondary.opacity(0.04),in:RoundedRectangle(cornerRadius:12))
                    }
                }
            }
            if sessions.isEmpty { Text("확인된 프로젝트 대화가 없습니다.").foregroundStyle(.secondary) }
        }.padding(24).frame(width:680,height:560).task { await inspect() }
    }
    private func inspect() async {
        guard let planID else {message="정리 계획을 다시 불러오세요.";return}
        do {
            let data=try await EnvironmentRetirementService.invoke(root:model.projectRoot,request:["action":"focus-target","id":planID,"item":item.id])
            let object=try JSONSerialization.jsonObject(with:data) as? [String:Any]
            let pids=(object?["pids"] as? [NSNumber] ?? []).map(\.int32Value)
            apps=pids.compactMap { NSRunningApplication(processIdentifier:$0) }.filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            message=apps.isEmpty ? "이 대상에 직접 연결된 앱 창은 확인되지 않았습니다. 위치와 대화를 확인할 수 있습니다." : "실행 프로세스의 상위 앱입니다. 정확한 창·탭은 연결이 확인되지 않았습니다."
            if model.sessionIndex == nil {model.refreshSessionIndex()}
        } catch {message=error.localizedDescription}
    }
}
