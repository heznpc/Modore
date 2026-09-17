import SwiftUI

struct HealthDashboardTiles: View {
    let snapshot: HealthSnapshot
    var peak: HealthSnapshot? = nil
    let storage: () -> Void
    let memory: () -> Void
    let cpu: () -> Void
    var body: some View {
        HStack(alignment:.top,spacing:16) {
            tile(L10n.text("저장공간"), "internaldrive", value:bytes(snapshot.freeBytes), detail:L10n.text("사용 가능한 공간"), status:snapshot.freeBytes.map { $0 < 20 * 1_073_741_824 ? L10n.text("부족") : L10n.text("여유 있음") } ?? L10n.text("미확인"), warning:snapshot.freeBytes.map { $0 < 20 * 1_073_741_824 } ?? false, action:L10n.text("전체 구성 보기"), run:storage)
            tile(L10n.text("메모리"), "memorychip", value:snapshot.memoryPressure.map { $0 >= 4 ? L10n.text("위험") : ($0 >= 2 ? L10n.text("주의") : L10n.text("안정")) } ?? L10n.text("미확인"), detail:L10n.text("스왑 ") + bytes(snapshot.swapBytes.map { Int64(clamping:$0) }), status:snapshot.memoryPressure == nil ? L10n.text("미확인") : ((snapshot.memoryPressure ?? 0) >= 2 ? L10n.text("RAM 압박") : L10n.text("macOS 메모리 압력")), warning:(snapshot.memoryPressure ?? 0) >= 2, action:L10n.text("앱 재시작"), run:memory)
            tile("CPU", "cpu", value:snapshot.cpuAvailable ? (snapshot.cpuElevated ? L10n.text("부하 지속") : (snapshot.cpuBurst == true ? L10n.text("순간 부하") : L10n.text("안정"))) : L10n.text("측정 중"), detail:snapshot.thermalPressure < 0 ? L10n.text("열 압력 미확인") : (snapshot.thermalPressure > 0 ? L10n.text("열 압력 감지") : L10n.text("열 압력 정상")), status:snapshot.cpuAvailable ? (snapshot.processes.max(by:{$0.cpu < $1.cpu}).map { "\($0.name) \(Int($0.cpu))%" } ?? L10n.text("측정 중")) : L10n.text("표본 수집 중"), warning:snapshot.cpuElevated || snapshot.cpuBurst == true, action:L10n.text("실행 작업 보기"), history:peak, run:cpu)
        }
    }
    private func bytes(_ n:Int64?) -> String { n.map { ByteCountFormatter.string(fromByteCount:$0,countStyle:.file) } ?? L10n.text("미확인") }
    private func tile(_ name:String,_ icon:String,value:String,detail:String,status:String,warning:Bool,action:String,history:HealthSnapshot? = nil,run:@escaping ()->Void) -> some View {
        let color:Color = [L10n.text("미확인"),L10n.text("측정 중")].contains(value) ? .secondary : (warning ? .orange : .teal)
        return Button(action:run) {
            VStack(alignment:.leading,spacing:12) {
                HStack { Image(systemName:icon).font(.title2).foregroundStyle(color); Text(name).font(.headline); Spacer(); Circle().fill(color).frame(width:8,height:8) }
                Text(value).font(.system(size:32,weight:.bold,design:.rounded)).minimumScaleFactor(0.6).lineLimit(1)
                VStack(alignment:.leading,spacing:6) {
                    Text(detail).font(.callout)
                    Label(status,systemImage:warning ? "exclamationmark.circle.fill" : "waveform.path").font(.caption).foregroundStyle(.secondary)
                }
                if let history {
                    VStack(alignment:.leading,spacing:3) {
                        Text(L10n.text("최근 CPU 부하") + " · " + history.date.formatted(date:.omitted,time:.standard))
                        Text(history.processes.max(by:{$0.cpu < $1.cpu}).map { "\($0.name) \(Int($0.cpu))%" } ?? "")
                    }.font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
                HStack { Text(action).font(.callout.weight(.semibold)); Spacer(); Image(systemName:"arrow.up.right") }.foregroundStyle(color)
            }.padding(18).frame(maxWidth:.infinity,alignment:.leading)
                .background(color.opacity(0.065),in:RoundedRectangle(cornerRadius:20)).contentShape(RoundedRectangle(cornerRadius:20))
        }.buttonStyle(.plain)
    }
}

struct HealthActionTile: View {
    let title, subtitle, icon: String
    let action: () -> Void
    var body: some View {
        Button(action:action) {
            HStack(spacing:14) {
                Image(systemName:icon).font(.system(size:27)).foregroundStyle(.teal).frame(width:36)
                VStack(alignment:.leading,spacing:6) { Text(title).font(.headline); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                Spacer(); Image(systemName:"arrow.right").foregroundStyle(.teal)
            }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                .background(Color.secondary.opacity(0.045),in:RoundedRectangle(cornerRadius:16)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
