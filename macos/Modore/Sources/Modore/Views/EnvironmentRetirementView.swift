import SwiftUI
import UniformTypeIdentifiers

struct EnvironmentRetirementView: View {
    @EnvironmentObject private var model: ScanModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = EnvironmentRetirementService()
    @State private var selected: Set<String> = []
    @State private var tab = "device"
    @State private var confirm = false
    @State private var platforms: Set<String> = ["iOS", "iPadOS", "watchOS"]
    @State private var schedule = false
    @State private var interval = 24.0
    @State private var minimumFree = 15.0
    @State private var scheduledCaches: Set<String> = []
    @State private var policyMessage = ""
    @State private var requirementProject = ""
    @State private var requirementPlatform = "iOS"
    @State private var requirementRuntime = ""
    @State private var requirements: [[String: String]] = []
    @State private var showPolicy = false
    @State private var appRecovery = false
    @State private var simulatorSetup = false
    @State private var folderAccess = false

    private var items: [EnvironmentItem] { service.plan?.items ?? [] }
    private var projects: [String] { Array(Set((model.sessionIndex?.sessions ?? []).map(\.workspace).filter { $0.hasPrefix("/") && $0 != NSHomeDirectory() })).sorted() }
    private var chosen: [EnvironmentItem] { items.filter { selected.contains($0.id) && !$0.finished } }
    private var selectionWarnings: [String] {
        var result: [String] = []
        for platform in platforms {
            let affected = items.contains { item in
                selected.contains(item.id) && ((item.kind == "device" && item.platform == platform) ||
                    (item.kind == "runtime" && items.contains { $0.kind == "device" && $0.platform == platform && $0.runtime == item.runtime }))
            }
            guard affected else { continue }
            let remaining = items.filter { $0.kind == "device" && $0.platform == platform && !selected.contains($0.id) && !$0.finished }
            if remaining.isEmpty { result.append("\(platform) 기기가 남지 않습니다.") }
            else if remaining.allSatisfy({ device in items.contains { $0.kind == "runtime" && $0.runtime == device.runtime && selected.contains($0.id) } }) {
                result.append("\(platform) 기기는 남지만 필요한 런타임이 삭제됩니다.")
            }
        }
        return result
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("환경 정리").font(.title2.bold())
                    Text("저장공간 삭제와 실행 환경 종료를 구분해서 선택하세요.").foregroundStyle(.secondary)
                }
                Spacer()
                if service.busy { ProgressView().controlSize(.small) }
                Button("폴더 접근 허용") { folderAccess = true }.disabled(service.executing)
                Button("앱 재시작") { appRecovery = true }.disabled(service.busy)
                Button("이전 기록") { perform(["action":"latest"]) }.disabled(service.busy)
                Button("다시 측정") { preview() }.disabled(service.busy)
                Button("닫기") { dismiss() }.disabled(service.executing).keyboardShortcut(.cancelAction)
            }.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let plan = service.plan {
                        capacitySummary(plan)
                        DisclosureGroup("유지할 개발 환경 · 예약 정리", isExpanded: $showPolicy) { policyEditor.padding(.top, 12) }
                        if !plan.missingPlatforms.isEmpty {
                            Button("필요한 OS·기종 준비") { simulatorSetup = true }
                            Label("필요하지만 없는 환경: " + plan.missingPlatforms.joined(separator: " · "), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        Picker("정리 종류", selection: $tab) {
                            Text("기기 데이터").tag("device")
                            Text("OS 런타임").tag("runtime")
                            Text("재생성 캐시").tag("cache")
                            Text("서버 종료").tag("process")
                            Text("VM 종료").tag("vm")
                            Text("SSD 추출").tag("volume")
                        }.pickerStyle(.segmented)
                        Text(["process","vm"].contains(tab) ? "정상 종료할 실행 환경을 선택하세요. 저장된 프로젝트·VM 디스크는 유지합니다." : (tab == "volume" ? "추출할 SSD를 선택하세요. 선택한 서버·VM 종료 뒤 추출합니다." : "삭제할 항목을 직접 선택하세요. 아무 항목도 자동 선택하지 않습니다."))
                            .font(.callout).foregroundStyle(.secondary)
                        if tab == "cache" {
                            Text("공유 재생성 캐시 전체: \(size(plan.cacheBytes)) · 런타임별 중복 합산을 하지 않습니다.")
                        }
                        if items.filter({ $0.kind == tab }).isEmpty {
                            Text("현재 이 종류의 정리 대상이 없습니다.").foregroundStyle(.secondary).padding(.vertical, 30)
                        }
                        ForEach(items.filter { $0.kind == tab }) { item in itemCard(item) }
                        if !selectionWarnings.isEmpty && !chosen.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Label("선택에 따른 영향 · 확인 후 계속할 수 있습니다", systemImage: "exclamationmark.triangle").font(.headline)
                                ForEach(selectionWarnings, id: \.self) { Text($0) }
                            }.foregroundStyle(.orange).padding(14).frame(maxWidth:.infinity, alignment:.leading)
                                .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius:10))
                        }
                        if !plan.warnings.isEmpty {
                            DisclosureGroup("일부 환경을 확인하지 못했습니다 · 상세") {
                                ForEach(plan.warnings, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                            }.foregroundStyle(.orange)
                        }
                        if let after = plan.after {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("실행 결과").font(.headline)
                                Text("명령 성공 \(items.filter(\.finished).count)개 · 사후 확인 \(items.filter { $0.verification == "verified" }.count)개")
                                Text("실제 여유 공간 \(size(plan.before.freeBytes)) → \(size(after.freeBytes))")
                                Text("순변화 \(after.freeBytes >= plan.before.freeBytes ? "+" : "−")\(size(abs(after.freeBytes-plan.before.freeBytes))) · 다른 앱의 변화도 포함됩니다.").foregroundStyle(.secondary)
                                Button("사후 상태·여유 공간 다시 확인") { perform(["action":"remeasure","id":plan.id]) }.disabled(service.busy)
                                DisclosureGroup("메모리 전후 · 실행 기록") {
                                    Text(plan.memoryBefore + "\n→\n" + plan.memoryAfter).font(.caption).textSelection(.enabled)
                                    Text("거래 " + plan.id).font(.caption).textSelection(.enabled)
                                }
                            }.padding(16).frame(maxWidth:.infinity, alignment:.leading).background(Color.blue.opacity(0.05), in:RoundedRectangle(cornerRadius:12))
                        }
                    } else {
                        Text(service.busy ? "기기·런타임·캐시와 프로젝트 서버를 측정하고 있습니다…" : "환경을 측정해 정리할 항목을 선택하세요.").padding(.vertical,40)
                    }
                    if !service.error.isEmpty { Text(service.error).foregroundStyle(.red).textSelection(.enabled) }
                }.padding(24)
            }
            Divider()
            HStack {
                if service.busy {
                    Text(service.executing ? "선택한 항목 처리 중" : "환경을 측정하고 있습니다").foregroundStyle(.secondary)
                    Spacer()
                    if service.executing { Button("이후 항목 취소") { service.cancel() } }
                } else {
                    Text("\(chosen.count)개 선택 · 파일 용량 \(size(chosen.compactMap(\.bytes).reduce(0,+)))").font(.headline)
                    Spacer()
                    Button("선택 해제") { selected = [] }
                    if let plan = service.plan, chosen.contains(where: { $0.approved && !$0.changed }) {
                        Button("승인된 항목 재시도") { perform(["action":"execute","id":plan.id,"ids":Array(selected)], mutation:true) }
                    }
                    Button(["process","vm"].contains(tab) ? "선택 검토·종료" : "선택 검토·실행") { confirm = true }
                        .buttonStyle(.borderedProminent).disabled(chosen.isEmpty)
                }
            }.padding(20)
        }.frame(width: 1000, height: 760)
        .fileImporter(isPresented:$folderAccess,allowedContentTypes:[.folder]) { result in
            do { try EnvironmentFolderAccess.grant(result.get());preview() }
            catch { service.error=error.localizedDescription }
        }
        .sheet(isPresented:$simulatorSetup) { SimulatorSetupView() }
        .sheet(isPresented:$appRecovery) { AppRecoveryView() }
        .interactiveDismissDisabled(service.executing)
        .task { preview() }
        .onChange(of: service.plan?.id) { _ in loadPolicy() }
        .confirmationDialog("선택한 항목을 실행합니다", isPresented: $confirm, titleVisibility:.visible) {
            Button("경고 확인 · 선택한 \(chosen.count)개 실행", role:.destructive) {
                let ids = chosen.map(\.id)
                Task { await service.approveAndRun(ids:ids, model:model) }
            }
            Button("취소", role:.cancel) {}
        } message: {
            Text((chosen.map { "\($0.name) · \(["process","vm"].contains($0.kind) ? "정상 종료" : ($0.kind == "volume" ? "추출" : "삭제"))" } + selectionWarnings).joined(separator:"\n"))
        }
    }
    private func capacitySummary(_ plan: EnvironmentPlan) -> some View {
        let c = plan.after ?? plan.before
        return VStack(alignment:.leading, spacing:10) {
            HStack {
                VStack(alignment:.leading) { Text("내부 디스크 여유").foregroundStyle(.secondary); Text(size(c.freeBytes)).font(.system(size:30,weight:.semibold)) }
                Spacer()
                VStack(alignment:.trailing) { Text("전체 \(size(c.totalBytes))"); Text("사용 \(size(c.totalBytes-c.freeBytes))").foregroundStyle(.secondary) }
            }
            ProgressView(value:Double(c.totalBytes-c.freeBytes),total:Double(c.totalBytes)).tint(c.freeBytes < 10_000_000_000 ? .orange : .blue)
            Text("삭제 대상의 합계와 실제 확보량은 다릅니다. 실행 후 지연되는 공간 반환을 다시 측정합니다.").font(.caption).foregroundStyle(.secondary)
        }.padding(18).background(Color.secondary.opacity(0.06), in:RoundedRectangle(cornerRadius:12))
    }
    private func itemCard(_ item: EnvironmentItem) -> some View {
        VStack(alignment:.leading, spacing:10) {
            HStack(spacing:12) {
                Toggle(isOn:Binding(get:{ selected.contains(item.id) },set:{ if $0 { selected.insert(item.id) } else { selected.remove(item.id) } })) {
                    Label(item.name, systemImage:item.icon).font(.headline)
                }.disabled(item.finished || item.changed || !item.invariant.isEmpty)
                Spacer()
                Text(item.bytes.map { size($0) } ?? (item.kind == "cache" ? "공유 캐시" : "")).monospacedDigit().foregroundStyle(.secondary)
            }
            Text(item.subtitle).foregroundStyle(.secondary)
            if !item.invariant.isEmpty { Label(item.invariant,systemImage:"lock").foregroundStyle(.orange) }
            DisclosureGroup("영향·연결 정보") {
                ForEach(item.warnings,id:\.self) { Text($0).font(.callout) }
                if !item.path.isEmpty { Text(item.path).font(.caption).textSelection(.enabled) }
                Text(item.runtime).font(.caption).textSelection(.enabled)
            }
            if item.mutation != "pending" { Text("실행: \(label(item.mutation)) · 사후 확인: \(label(item.verification))").font(.callout) }
            if !item.error.isEmpty { Text(item.error).foregroundStyle(.orange) }
            if item.changed, let plan=service.plan { Button("이 항목 다시 확인") { perform(["action":"refresh","id":plan.id,"ids":[item.id]]) } }
        }.padding(16).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(Color.primary.opacity(0.08)))
    }
    private var policyEditor: some View {
        VStack(alignment:.leading, spacing:12) {
            Text("필요한 플랫폼").font(.headline)
            HStack { ForEach(["iOS","iPadOS","watchOS"],id:\.self) { p in
                Toggle(p,isOn:Binding(get:{platforms.contains(p)},set:{if $0 {platforms.insert(p)} else {platforms.remove(p)}}))
            } }
            Text("플랫폼 요구는 삭제 경고에 반영됩니다. 사용자가 확인하면 선택을 바꿀 수 있습니다.").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("프로젝트별 OS 요구") {
                ForEach(Array(requirements.enumerated()),id:\.offset) { index, requirement in
                    HStack { Text("\(URL(fileURLWithPath:requirement["project"] ?? "").lastPathComponent) · \(requirement["platform"] ?? "") · \(requirement["runtime"] ?? "")"); Spacer(); Button("제거") { requirements.remove(at:index) } }.font(.caption)
                }
                Picker("프로젝트",selection:$requirementProject) { Text("선택").tag(""); ForEach(projects,id:\.self) { Text(URL(fileURLWithPath:$0).lastPathComponent).tag($0) } }
                Picker("플랫폼",selection:$requirementPlatform) { ForEach(["iOS","iPadOS","watchOS"],id:\.self) { Text($0).tag($0) } }
                TextField("필요한 OS 버전 (예: 26.5)",text:$requirementRuntime)
                Button("요구 추가") { requirements.append(["project":requirementProject,"platform":requirementPlatform,"runtime":"com.apple.CoreSimulator.SimRuntime." + (requirementPlatform == "iPadOS" ? "iOS" : requirementPlatform) + "-" + requirementRuntime.replacingOccurrences(of:".",with:"-")]);requirementRuntime="" }
                    .disabled(requirementProject.isEmpty || requirementRuntime.isEmpty)
            }
            Divider()
            Toggle("Modore 실행 중 예약 정리",isOn:$schedule)
            Text("아래에서 허용한 재생성 캐시만 정리합니다. 기기·런타임·서버는 자동 삭제·종료하지 않습니다. 화면을 깨우는 알림을 보내지 않습니다.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Stepper("\(Int(interval))시간마다",value:$interval,in:1...168)
                Stepper("여유 \(Int(minimumFree))GB 미만일 때",value:$minimumFree,in:1...200)
            }
            ForEach(items.filter { $0.kind == "cache" }) { item in
                Toggle(item.name,isOn:Binding(get:{scheduledCaches.contains(item.id)},set:{if $0 {scheduledCaches.insert(item.id)} else {scheduledCaches.remove(item.id)}}))
            }
            if let status=service.plan?.policy.lastStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
            if let next=service.plan?.policy.nextRunAt { Text("다음 확인: \(Date(timeIntervalSince1970:next).formatted())").font(.caption) }
            Button("유지 요구·예약 정책 저장") { savePolicy() }.disabled(service.busy)
            if !policyMessage.isEmpty { Text(policyMessage).font(.caption) }
        }.padding(14).background(Color.secondary.opacity(0.04),in:RoundedRectangle(cornerRadius:10))
    }
    private func loadPolicy() {
        guard let p=service.plan?.policy else { return }
        platforms=Set(p.platforms);schedule=p.scheduleEnabled;interval=p.intervalHours;minimumFree=p.minimumFreeGB;scheduledCaches=Set(p.cacheIDs)
        requirements=p.requirements.map { ["project":$0.project,"platform":$0.platform,"runtime":$0.runtime] }
    }
    private func savePolicy() {
        Task {
            do {
                _ = try await EnvironmentRetirementService.invoke(root:model.projectRoot,request:["action":"policy","platforms":Array(platforms),"requirements":requirements,"scheduleEnabled":schedule,"intervalHours":interval,"minimumFreeGB":minimumFree,"cacheIDs":Array(scheduledCaches)])
                policyMessage="저장했습니다. 새 계획에 반영됩니다."
                preview()
            } catch { policyMessage=error.localizedDescription }
        }
    }
    private func preview() { selected=[]; perform(["action":"preview","projects":projects]) }
    private func perform(_ req:[String:Any],mutation:Bool=false) { Task { await service.perform(req,model:model,mutation:mutation) } }
    private func size(_ value:Int64?) -> String { value.map { ByteCountFormatter.string(fromByteCount:$0,countStyle:.file) } ?? "개별 용량 미측정" }
    private func label(_ value:String) -> String {
        ["succeeded":"성공","verified":"확인됨","pending":"대기","attempting":"진행 중","failed":"실패","requested":"캐시 제거 응답 확인 · 공간 별도 측정"][value] ?? value
    }
}
