import SwiftUI

/// An always-visible preview of the environment remaining after the current selection.
struct EnvironmentConditionBoard: View {
    let items: [EnvironmentItem]
    let selected: Set<String>
    @Binding var required: Set<String>
    let prepare: () -> Void

    var body: some View {
        HStack(spacing:12) {
            ForEach(["iOS","iPadOS","watchOS"],id:\.self) { platform in
                platformTile(platform)
            }
        }
    }
    private func platformTile(_ platform:String) -> some View {
        let devices = items.filter { $0.kind == "device" && $0.platform == platform && !$0.finished }
        let remaining = devices.filter { device in
            !selected.contains(device.id) && !items.contains { $0.kind == "runtime" && $0.runtime == device.runtime && (selected.contains($0.id) || $0.finished) }
        }
        let affected = remaining.count != devices.count
        let tint: Color = affected ? .orange : (devices.isEmpty ? .secondary : .teal)
        return VStack(alignment:.leading,spacing:12) {
            HStack {
                Image(systemName:platform == "iOS" ? "iphone" : (platform == "iPadOS" ? "ipad" : "applewatch"))
                    .font(.system(size:30)).foregroundStyle(tint)
                Spacer()
                Toggle(isOn:Binding(get:{required.contains(platform)},set:{if $0 {required.insert(platform)} else {required.remove(platform)}})) {
                    Label(L10n.text("유지"),systemImage:required.contains(platform) ? "pin.fill" : "pin").padding(.vertical,5).padding(.horizontal,3)
                }.toggleStyle(.button).help(L10n.format("%@ 유지 조건 · 이번 검토에 적용, 저장은 자동 정리·유지 조건에서", String(describing: platform)))
                    .accessibilityLabel(L10n.format("%@ 유지 조건", String(describing: platform)))
            }
            HStack(alignment:.firstTextBaseline) {
                Text(platform).font(.headline)
                Spacer()
                Text("\(devices.count)").font(.system(size:24,weight:.bold,design:.rounded))
                if affected { Image(systemName:"arrow.right").font(.caption); Text("\(remaining.count)").font(.system(size:24,weight:.bold,design:.rounded)).foregroundStyle(.orange) }
            }
            if devices.isEmpty {
                Button(action:prepare) { Label(L10n.text("기기 준비"),systemImage:"plus.circle") }.buttonStyle(.plain).foregroundStyle(.teal)
            } else {
                Label(affected ? (remaining.isEmpty ? L10n.text("정리 후 기기 없음") : L10n.text("정리 후 남는 기기")) : L10n.text("사용 가능"),systemImage:affected ? "exclamationmark.circle" : "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(tint)
            }
        }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
            .background(tint.opacity(0.065),in:RoundedRectangle(cornerRadius:16))
            .overlay(RoundedRectangle(cornerRadius:16).stroke(affected ? Color.orange.opacity(0.6) : Color.clear))
    }
}

struct EnvironmentConditionChips: View {
    let item: EnvironmentItem
    let selected: Bool
    let required: Bool
    private var running: Bool { ["Running","Booted"].contains(item.state) }
    private var connections: Int { item.warnings.filter { $0.hasPrefix("연결된 작업:") }.count }
    var body: some View {
        ViewThatFits(in:.horizontal) {
            HStack(spacing:8) { chips }
            VStack(alignment:.leading,spacing:8) { chips }
        }
    }
    @ViewBuilder private var chips: some View {
        chip(running ? L10n.text("실행 중") : item.state == "Shutdown" ? L10n.text("꺼짐") : "\(item.state == "Ready" ? "설치됨" : item.state == "Mounted" ? "연결됨" : item.state)",running ? "play.fill" : "circle",running ? .teal : .secondary)
        if connections > 0 { chip(L10n.format("작업 %@개 연결", String(describing: connections)),"link",.orange) }
        if !item.project.isEmpty { chip(URL(fileURLWithPath:item.project).lastPathComponent,"folder",.teal) }
        if required || item.warnings.contains(where:{$0.contains("유지 표시") || $0.hasPrefix("프로젝트 요구:")}) { chip(L10n.text("유지 조건"),"pin.fill",.orange) }
        if !item.invariant.isEmpty { chip(L10n.text("확인 필요"),"lock",.orange) }
        else { chip(effect,selected ? "arrow.right.circle.fill" : "arrow.right.circle",selected ? .orange : .secondary) }
    }
    private var effect:String {
        switch item.kind {
        case "registration": return L10n.text("등록 해제 · 앱 유지")
        case "device": return L10n.text("테스트 데이터 삭제")
        case "runtime": return L10n.text("OS 제거")
        case "cache": return L10n.text("재생성 가능")
        case "volume": return L10n.text("연결 해제")
        default: return L10n.text("종료 · 파일 유지")
        }
    }
    private func chip(_ text:String,_ icon:String,_ color:Color) -> some View {
        Label(text,systemImage:icon).font(.caption.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal,9).padding(.vertical,6).background(color.opacity(0.09),in:Capsule())
    }
}
