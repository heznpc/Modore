import SwiftUI
import UniformTypeIdentifiers

struct EnvironmentRetirementView: View {
    @EnvironmentObject private var model: ScanModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = EnvironmentRetirementService()
    @State private var selected: Set<String> = []
    @State private var appQuery = ""
    @State private var expandedProjects: Set<String> = []
    @State private var tab = "space"
    var initialTab: String = "space"
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
            HStack(spacing: 12) {
                Image(systemName:"square.stack.3d.up.fill").font(.title2).foregroundStyle(.teal)
                Text("작업대").font(.title2.bold())
                Spacer()
                if service.busy { ProgressView().controlSize(.small) }
                Button { preview() } label: { Image(systemName:"arrow.clockwise") }.help("다시 측정").disabled(service.busy)
                Menu {
                    Button("정리 기록") { perform(["action":"latest"]) }
                    Button("자동 정리·유지 조건") { showPolicy = true }
                    Button("폴더 접근 허용") { folderAccess = true }
                } label: { Image(systemName:"ellipsis") }.disabled(service.executing)
                Button { dismiss() } label: { Image(systemName:"xmark") }.keyboardShortcut(.cancelAction).disabled(service.executing)
            }.buttonStyle(.plain).padding(24)
            HStack(alignment:.top, spacing:0) {
                RetirementIntentRail(selection:$tab, freeBytes:service.plan.map { ($0.after ?? $0.before).freeBytes })
                ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let plan = service.plan {
                        VStack(alignment:.leading,spacing:8) {
                            Text(intentTitle).font(.system(size:32,weight:.bold))
                            HStack(spacing:16) { Label("선택",systemImage:"checkmark.circle"); Image(systemName:"chevron.right"); Label("영향 확인",systemImage:"square.stack.3d.up"); Image(systemName:"chevron.right"); Label("실행",systemImage:"play.fill") }.font(.caption).foregroundStyle(.secondary)
                        }.padding(.bottom,8)
                        if tab == "finish" {
                            Button { appRecovery = true } label: { Label("앱만 다시 시작하기",systemImage:"arrow.clockwise.circle") }
                        }
                        if tab == "space" {
                            EnvironmentConditionBoard(items:items,selected:selected,required:$platforms) { simulatorSetup=true }
                        }
                        if tab == "apps" { Text("실제 복사본과 파일 없는 등록을 구분합니다. 선택한 항목은 등록만 해제하며, 메뉴 막대 항목 제거 여부는 별도 확인이 필요합니다.").font(.callout).foregroundStyle(.secondary) }
                        if tab == "apps" { TextField("앱 이름·번들 ID·경로 검색",text:$appQuery).textFieldStyle(.roundedBorder) }
                        ForEach(visibleKinds,id: \.self) { kind in
                            let group = items.filter { $0.kind == kind && (kind != "registration" || appQuery.isEmpty || ($0.name + $0.path + $0.target).localizedCaseInsensitiveContains(appQuery)) }
                            if kind == "cache", plan.cacheBytes == 0 {
                                Label("캐시는 이미 비어 있습니다",systemImage:"checkmark.circle").font(.callout).foregroundStyle(.secondary)
                            } else if !group.isEmpty {
                                VStack(alignment:.leading,spacing:12) {
                                    HStack {
                                        Text(groupTitle(kind)).font(.headline)
                                        Spacer()
                                        Text("\(["process","registration"].contains(kind) ? Set(group.map(\.project)).count : group.count)개").foregroundStyle(.secondary)
                                    }
                                    if kind == "cache" { Text("공유 캐시 \(size(plan.cacheBytes)) · 다시 만들어지는 자료").font(.caption).foregroundStyle(.secondary) }
                                    if kind == "process" || kind == "registration" { projectGroups(group) }
                                    else { ForEach(group) { item in itemCard(item) } }
                                }
                            }
                        }
                        if !items.contains(where: { visibleKinds.contains($0.kind) }) {
                            VStack(spacing:12) {
                                Image(systemName:"checkmark.circle").font(.system(size:40)).foregroundStyle(.teal)
                                Text("지금 정리할 대상이 없습니다").font(.headline)
                                Text("다시 측정하면 현재 상태를 확인합니다.").foregroundStyle(.secondary)
                            }.frame(maxWidth:.infinity).padding(.vertical,60)
                        }
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
                }.padding(28)
                }
            }
            Divider()
            HStack {
                if service.busy {
                    Text(service.executing ? "선택한 항목 처리 중" : "환경을 측정하고 있습니다").foregroundStyle(.secondary)
                    Spacer()
                    if service.executing { Button("이후 항목 취소") { service.cancel() } }
                } else {
                    Text(chosen.isEmpty ? "대상을 선택하면 여기에 모입니다" : "\(chosen.count)개 선택" + (chosen.compactMap(\.bytes).isEmpty ? "" : " · \(size(chosen.compactMap(\.bytes).reduce(0,+)))")).font(.headline).foregroundStyle(chosen.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button("선택 해제") { selected = [] }
                    if let plan = service.plan, chosen.contains(where: { $0.approved && !$0.changed }) {
                        Button("승인된 항목 재시도") { perform(["action":"execute","id":plan.id,"ids":Array(selected)], mutation:true) }
                    }
                    Button("\(chosen.count)개 검토하기") { confirm = true }
                        .buttonStyle(.borderedProminent).disabled(chosen.isEmpty)
                }
            }.padding(20)
        }.frame(width: 1000, height: 760)
        .fileImporter(isPresented:$folderAccess,allowedContentTypes:[.folder]) { result in
            do { try EnvironmentFolderAccess.grant(result.get());preview() }
            catch { service.error=error.localizedDescription }
        }
        .sheet(isPresented:$showPolicy) {
            VStack(alignment:.leading,spacing:16) {
                HStack { Text("자동 정리·유지 조건").font(.title2.bold()); Spacer(); Button("닫기") { showPolicy=false } }
                ScrollView { policyEditor }
            }.padding(24).frame(width:640,height:620)
        }
        .sheet(isPresented:$simulatorSetup) { SimulatorSetupView() }
        .sheet(isPresented:$appRecovery) { AppRecoveryView() }
        .interactiveDismissDisabled(service.executing)
        .task { tab=initialTab;preview() }
        .onChange(of: service.plan?.id) { _ in loadPolicy() }
        .confirmationDialog("선택한 항목을 실행합니다", isPresented: $confirm, titleVisibility:.visible) {
            Button("경고 확인 · 선택한 \(chosen.count)개 실행", role:.destructive) {
                let ids = chosen.map(\.id)
                Task { await service.approveAndRun(ids:ids, model:model) }
            }
            Button("취소", role:.cancel) {}
        } message: {
            Text((chosen.map { "\($0.name) · \($0.actionLabel)" } + selectionWarnings).joined(separator:"\n"))
        }
    }
    private var visibleKinds: [String] {
        tab == "apps" ? ["registration"] : tab == "space" ? ["cache","device","runtime"] : (tab == "finish" ? ["process","vm"] : ["volume","process","vm"])
    }
    private var intentTitle: String { tab == "apps" ? "앱 중복 정리" : tab == "space" ? "가볍게 만들기" : (tab == "finish" ? "오늘 작업 마치기" : "SSD 가져가기") }
    private var intentDetail: String {
        tab == "space" ? "다시 만들 수 있는 자료부터 살펴보세요. 기기와 OS는 필요한 만큼 남깁니다." :
        (tab == "finish" ? "프로젝트 서버와 가상머신을 정상 종료합니다. 작업 파일은 그대로 남습니다." : "드라이브와 연결된 작업을 살펴보고, 종료할 작업과 추출할 SSD를 함께 선택하세요.")
    }
    private func groupTitle(_ kind:String) -> String {
        ["cache":"다시 만들어지는 자료", "device":"내 테스트 기기", "runtime":"기기가 사용하는 OS", "process":"실행 중인 프로젝트", "vm":"가상머신", "volume":"연결된 드라이브", "registration":"중복 이름으로 등록된 앱"][kind] ?? kind
    }
    private func projectGroups(_ group:[EnvironmentItem]) -> some View {
        let paths = Array(Set(group.map(\.project))).sorted()
        return LazyVGrid(columns:group.first?.kind == "registration" && expandedProjects.isEmpty ? [GridItem(.flexible()),GridItem(.flexible())] : [GridItem(.flexible())],spacing:12) {
            ForEach(paths,id: \.self) { path in
                let members = group.filter { $0.project == path }
                VStack(alignment:.leading,spacing:12) {
                    Button {
                        if expandedProjects.contains(path) { expandedProjects.remove(path) } else { expandedProjects.insert(path) }
                    } label: {
                        HStack(spacing:12) {
                            Image(systemName:"folder").font(.title2).foregroundStyle(.teal)
                            VStack(alignment:.leading,spacing:6) {
                                Text(members.first?.kind == "registration" ? (members.first?.name ?? path) : (path.isEmpty ? "연결 프로젝트 미확인" : URL(fileURLWithPath:path).lastPathComponent)).font(.headline)
                                HStack { Label("\(members.first?.kind == "registration" ? "등록" : "실행") \(members.count)",systemImage:"square.stack").foregroundStyle(.teal); Label("선택 \(members.filter { selected.contains($0.id) }.count)",systemImage:"checkmark.circle"); Label("파일 유지",systemImage:"doc") }.font(.caption)
                            }
                            Spacer()
                            Text(expandedProjects.contains(path) ? "작업 접기" : "작업 보기").font(.callout).foregroundStyle(.teal)
                        }.padding(16).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if expandedProjects.contains(path) { ForEach(members) { item in itemCard(item) }.padding(.horizontal,12) }
                }.padding(.bottom,expandedProjects.contains(path) ? 12 : 0).background(Color.secondary.opacity(0.035),in:RoundedRectangle(cornerRadius:16))
            }
        }
    }
    private func itemCard(_ item: EnvironmentItem) -> some View {
        VStack(alignment:.leading, spacing:10) {
            HStack(spacing:12) {
                Toggle(isOn:Binding(get:{ selected.contains(item.id) },set:{ if $0 { selected.insert(item.id) } else { selected.remove(item.id) } })) {
                    HStack(spacing:14) {
                        Image(systemName:item.icon).font(.system(size:26)).foregroundStyle(.teal).frame(width:38,height:44)
                        VStack(alignment:.leading,spacing:5) { Text(item.displayName).font(.headline).lineLimit(2) }
                    }
                }.disabled(item.finished || item.changed || !item.invariant.isEmpty)
                Spacer()
                Text(item.bytes.map { size($0) } ?? (item.kind == "cache" ? "공유 캐시" : "")).monospacedDigit().foregroundStyle(.secondary)
            }
            if item.kind == "registration" { VStack(alignment:.leading,spacing:4) { Text(item.platform + " · " + item.runtime); Text(item.path).foregroundStyle(.secondary).textSelection(.enabled) }.font(.caption) }
            EnvironmentConditionChips(item:item,selected:selected.contains(item.id),required:platforms.contains(item.platform) && item.kind == "device")
            if !item.invariant.isEmpty {
                HStack { Label(item.invariant,systemImage:"exclamationmark.circle").font(.callout).foregroundStyle(.orange); Spacer(); Button("폴더 연결") { folderAccess=true } }
            }
            ForEach(item.warnings.filter { $0.hasPrefix("연결된 작업:") || $0.hasPrefix("프로젝트 요구:") },id:\.self) { warning in
                Label(warning,systemImage:"link").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if item.mutation != "pending" { Text("실행: \(label(item.mutation)) · 사후 확인: \(label(item.verification))").font(.callout) }
            if !item.error.isEmpty { Text(item.error).foregroundStyle(.orange) }
            if item.changed, let plan=service.plan { Button("이 항목 다시 확인") { perform(["action":"refresh","id":plan.id,"ids":[item.id]]) } }
        }.padding(16).background(selected.contains(item.id) ? Color.teal.opacity(0.08) : Color.secondary.opacity(0.035),in:RoundedRectangle(cornerRadius:16))
            .overlay(RoundedRectangle(cornerRadius:16).stroke(selected.contains(item.id) ? Color.teal.opacity(0.6) : Color.primary.opacity(0.06)))
            .contextMenu {
                if !item.path.isEmpty { Text(item.path) }
                Text(item.runtime)
                ForEach(item.warnings,id:\.self) { Text($0) }
            }
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
