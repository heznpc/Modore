import SwiftUI

private struct DiskBalance: Decodable {
    struct Volume: Decodable { let name: String; let bytes: Int64 }
    struct Directory: Decodable { let name, path: String; let bytes: Int64?; let complete: Bool; var directory: Bool? }
    let observedAt: Double
    let totalBytes, freeBytes: Int64
    let volumes: [Volume]
    let directories: [Directory]
    let warnings: [String]
}
private struct DirectoryBalance: Decodable { let path:String; let observedAt:Double; let entries:[DiskBalance.Directory] }
struct FullStorageBalanceView: View {
    @EnvironmentObject private var model: ScanModel
    @State private var balance: DiskBalance?
    @State private var folder: DirectoryBalance?
    @State private var busy = false
    @State private var error = ""
    @State private var query = ""
    @State private var appDuplicates = false
    @State private var workbench = false
    private let colors:[Color] = [.teal,.indigo,.orange,.purple,.blue,.mint,.gray]
    private var entries:[DiskBalance.Directory] { (folder?.entries ?? balance?.directories ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) } }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                HStack {
                    VStack(alignment:.leading,spacing:6) {
                        Text("공간 지도").font(.system(size:32,weight:.bold))
                        if let balance { Text("전체 측정 " + Date(timeIntervalSince1970:balance.observedAt).formatted()).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button("전체 다시 측정") { folder=nil;measure(fresh:true) }.disabled(busy)
                }
                if let balance { volumeMap(balance) }
                HStack(spacing:16) {
                    HealthActionTile(title:"앱 중복 찾기",subtitle:"설치 복사본 · 남은 등록",icon:"square.on.square") { appDuplicates=true }
                    HealthActionTile(title:"개발 환경 정리",subtitle:"시뮬레이터 · 서버 · SSD",icon:"square.stack.3d.up") { workbench=true }
                }
                HStack {
                    Button { folder=nil;query="" } label: { Label("내부 디스크",systemImage:"internaldrive") }.buttonStyle(.plain)
                    if let folder { Image(systemName:"chevron.right"); Text(URL(fileURLWithPath:folder.path).lastPathComponent).fontWeight(.semibold); Button("상위 폴더") { browse(URL(fileURLWithPath:folder.path).deletingLastPathComponent().path) }.disabled(busy) }
                    Spacer()
                    TextField("이름으로 찾기",text:$query).textFieldStyle(.roundedBorder).frame(width:180)
                }
                if busy { ProgressView("용량 측정 중").frame(maxWidth:.infinity,alignment:.leading) }
                LazyVGrid(columns:[GridItem(.adaptive(minimum:220),spacing:14)],spacing:14) {
                    ForEach(Array(entries.enumerated()),id:\.element.path) { index,item in directoryTile(item,index:index) }
                }
                Text("폴더 크기 = 파일 할당량 · 최소 = 일부 접근 제한 · 미측정 ≠ 0 · APFS 공유 블록 때문에 위 물리 용량과 합계가 다를 수 있습니다.").font(.caption).foregroundStyle(.secondary)
                if !error.isEmpty { Label(error,systemImage:"exclamationmark.circle").foregroundStyle(.orange) }
            }.padding(26)
        }.task { measure(fresh:false) }
            .navigationDestination(isPresented:$appDuplicates) { EnvironmentRetirementView(initialTab:"apps") }
            .navigationDestination(isPresented:$workbench) { EnvironmentRetirementView() }
    }
    private func segmentWidth(_ width:CGFloat,_ bytes:Int64,_ total:Int64)->CGFloat { max(CGFloat(0),width * CGFloat(bytes) / CGFloat(max(total,1)) - 1) }
    private func volumeMap(_ b:DiskBalance)->some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(alignment:.firstTextBaseline) {
                Text(size(b.freeBytes)).font(.system(size:36,weight:.bold,design:.rounded))
                Text("여유").foregroundStyle(.secondary)
                Spacer(); Text("전체 " + size(b.totalBytes)).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                HStack(spacing:1) {
                    ForEach(Array(b.volumes.enumerated()),id:\.offset) { i,v in
                        Rectangle().fill(colors[i % colors.count]).frame(width:segmentWidth(geo.size.width,v.bytes,b.totalBytes)).help(v.name + " " + size(v.bytes))
                    }
                    Rectangle().fill(Color.secondary.opacity(0.12))
                }.clipShape(RoundedRectangle(cornerRadius:10))
            }.frame(height:42)
            LazyVGrid(columns:[GridItem(.adaptive(minimum:150),alignment:.leading)],alignment:.leading,spacing:12) {
                ForEach(Array(b.volumes.enumerated()),id:\.offset) { i,v in
                    HStack(spacing:8) { RoundedRectangle(cornerRadius:3).fill(colors[i % colors.count]).frame(width:10,height:24); VStack(alignment:.leading,spacing:3) { Text(v.name).font(.caption); Text(size(v.bytes)).font(.callout.weight(.semibold)) } }
                }
            }
        }.padding(22).background(Color.teal.opacity(0.045),in:RoundedRectangle(cornerRadius:20))
    }
    private func directoryTile(_ item:DiskBalance.Directory,index:Int)->some View {
        let color=colors[index % colors.count]
        let maxBytes=max(entries.compactMap(\.bytes).max() ?? 1,1)
        return Button {
            if item.directory == false { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:item.path)]) }
            else { browse(item.path) }
        } label: {
            VStack(alignment:.leading,spacing:14) {
                HStack { Image(systemName:item.directory == false ? "doc" : "folder.fill").font(.system(size:30)).foregroundStyle(color); Spacer(); Image(systemName:"arrow.up.right").foregroundStyle(.secondary) }
                Text(item.name).font(.headline).lineLimit(1)
                Text(item.bytes.map { (item.complete ? "" : "최소 ") + size($0) } ?? "미측정").font(.system(size:23,weight:.semibold,design:.rounded))
                if let n=item.bytes { ProgressView(value:Double(n),total:Double(maxBytes)).tint(color) }
                else { Label("접근·측정 확인 필요",systemImage:"questionmark.circle").font(.caption).foregroundStyle(.orange) }
            }.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(color.opacity(0.06),in:RoundedRectangle(cornerRadius:16)).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(busy).help(item.path)
            .contextMenu { Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:item.path)]) }; Text(item.path) }
    }
    private func browse(_ path:String) {
        guard !busy else{return};busy=true;error="";query=""
        Task { defer{busy=false};do { let data=try await EnvironmentRetirementService.invoke(root:model.projectRoot,request:["action":"directory","path":path]);folder=try JSONDecoder().decode(DirectoryBalance.self,from:data) } catch { self.error=error.localizedDescription } }
    }
    private func measure(fresh:Bool) {
        guard !busy else{return};busy=true;error=""
        Task { defer{busy=false};do { let data=try await EnvironmentRetirementService.invoke(root:model.projectRoot,request:["action":"balance","fresh":fresh]);balance=try JSONDecoder().decode(DiskBalance.self,from:data) } catch { self.error=error.localizedDescription } }
    }
    private func size(_ b:Int64)->String { ByteCountFormatter.string(fromByteCount:b,countStyle:.file) }
}
