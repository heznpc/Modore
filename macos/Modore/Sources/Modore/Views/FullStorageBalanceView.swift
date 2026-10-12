import SwiftUI

struct DiskBalance: Decodable, Sendable {
    struct Volume: Decodable, Sendable { let name: String; let bytes: Int64 }
    struct Directory: Decodable, Sendable { let name, path: String; let bytes: Int64?; let complete: Bool; var directory: Bool?; var classification: String?; var evidence: String?; var cleanupReview: Bool? }
    struct AccessIssue: Decodable, Sendable { let path, reason: String }
    struct Change: Decodable, Sendable { let path: String; let bytes, previousBytes, deltaBytes: Int64; let previousAt: Double }
    struct UAFMetadata: Decodable, Sendable {
        struct Row: Decodable, Sendable { let name: String; let logicalBytes: Int64 }
        let recordedAt: Double
        let rows: [Row]
    }
    let observedAt: Double
    let totalBytes, freeBytes: Int64
    let volumes: [Volume]
    let directories: [Directory]
    let warnings: [String]
    var dataVolumeBytes, scannedAllocatedBytes, accountingDifferenceBytes: Int64?
    var findings: [Directory]?
    var accessIssues: [AccessIssue]?
    var changes: [Change]?
    var scanStatus: String?
    var uafMetadata: UAFMetadata?

    static func latest() -> Self? {
        let url = StorageHistoryStore.stateDirectory.appendingPathComponent("environment-retirement/disk-balance.json")
        guard let data = try? SecureLocalFileIO.boundedRead(from: url, maximumBytes: 8_000_000) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    var candidates: [StorageItem] {
        (findings ?? []).filter { $0.cleanupReview == true }.compactMap { row in
            StorageItem(json: ["kind": "project_residue", "cleanupId": "project_residue",
                "path": row.path, "label": URL(fileURLWithPath: row.path).deletingLastPathComponent().lastPathComponent + " · " + row.name,
                "measureStatus": "historical", "sizeGB": 0,
                "note": "전체 볼륨 조사에서 발견 · \(Date(timeIntervalSince1970: observedAt).formatted()) · 현재 크기·사용 여부 재검증 필요"])
        }
    }
}
private struct DirectoryBalance: Decodable { let path:String; let observedAt:Double; let entries:[DiskBalance.Directory] }
struct FullStorageBalanceView: View {
    var onReviewCleanup: ((String) -> Void)? = nil
    @EnvironmentObject private var model: ScanModel
    @State private var balance: DiskBalance?
    @State private var folder: DirectoryBalance?
    @State private var busy = false
    @State private var error = ""
    @State private var query = ""
    @State private var findingsQuery = ""
    @State private var appDuplicates = false
    @State private var workbench = false
    private let colors:[Color] = [.teal,.indigo,.orange,.purple,.blue,.mint,.gray]
    private var entries:[DiskBalance.Directory] { (folder?.entries ?? balance?.directories ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) } }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                HStack {
                    VStack(alignment:.leading,spacing:6) {
                        Text(L10n.text("공간 지도")).font(.system(size:32,weight:.bold))
                        if let balance { Text(L10n.text("전체 측정 ") + Date(timeIntervalSince1970:balance.observedAt).formatted()).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button(L10n.text("전체 다시 측정")) { folder=nil;measure(fresh:true) }.disabled(busy)
                }
                if let balance { volumeMap(balance) }
                if folder == nil, let balance { investigationSummary(balance) }
                HStack(spacing:16) {
                    HealthActionTile(title:L10n.text("앱 중복 찾기"),subtitle:L10n.text("설치 복사본 · 남은 등록"),icon:"square.on.square") { appDuplicates=true }
                    HealthActionTile(title:L10n.text("개발 환경 정리"),subtitle:L10n.text("시뮬레이터 · 서버 · SSD"),icon:"square.stack.3d.up") { workbench=true }
                }
                HStack {
                    Button { folder=nil;query="" } label: { Label(L10n.text("내부 디스크"),systemImage:"internaldrive") }.buttonStyle(.plain)
                    if let folder { Image(systemName:"chevron.right"); Text(URL(fileURLWithPath:folder.path).lastPathComponent).fontWeight(.semibold); Button(L10n.text("상위 폴더")) { browse(URL(fileURLWithPath:folder.path).deletingLastPathComponent().path) }.disabled(busy) }
                    Spacer()
                    TextField(L10n.text("이름으로 찾기"),text:$query).textFieldStyle(.roundedBorder).frame(width:180)
                }
                if busy { ProgressView(L10n.text("용량 측정 중")).frame(maxWidth:.infinity,alignment:.leading) }
                LazyVGrid(columns:[GridItem(.adaptive(minimum:220),spacing:14)],spacing:14) {
                    ForEach(Array(entries.enumerated()),id:\.element.path) { index,item in
                        VStack(alignment:.leading) {
                            directoryTile(item,index:index)
                            if item.cleanupReview == true, let onReviewCleanup {
                                Button(L10n.text("정리 후보에서 검토"), action:{ onReviewCleanup(item.path) })
                            }
                        }
                    }
                }
                Text(L10n.text("폴더 크기 = 파일 할당량 · 최소 = 일부 접근 제한 · 미측정 ≠ 0 · APFS 공유 블록 때문에 위 물리 용량과 합계가 다를 수 있습니다.")).font(.caption).foregroundStyle(.secondary)
                if !error.isEmpty { Label(L10n.message(error),systemImage:"exclamationmark.circle").foregroundStyle(.orange) }
            }.padding(26)
        }.task { measure(fresh:false) }
            .navigationDestination(isPresented:$appDuplicates) { EnvironmentRetirementView(initialTab:"apps") }
            .navigationDestination(isPresented:$workbench) { EnvironmentRetirementView() }
    }
    private func investigationSummary(_ b: DiskBalance) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let allocated = b.scannedAllocatedBytes {
                Text("Data 볼륨 \(b.dataVolumeBytes.map(size) ?? "미측정") · 파일 할당량 \(b.scanStatus == "complete" ? "" : "최소 ")\(size(allocated)) · 미설명 차이 \(b.accountingDifferenceBytes.map(size) ?? "미측정")")
                    .font(.callout.weight(.semibold))
            }
            Text(b.scanStatus == "complete" ? "전체 순회 완료 · 아래 범위·회계 차이 확인 필요" : "전체 설명 미완료 · 접근 실패·측정 범위를 확인하세요")
                .foregroundStyle(.secondary)
            ForEach(b.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            if b.scanStatus == nil {
                Text("이전 방식의 기록입니다. 전체 다시 측정을 실행하면 알려진 캐시 목록 밖의 큰 경로도 조사합니다.")
                    .font(.callout)
            }
            DisclosureGroup("전체 조사에서 찾은 큰 경로 · \(b.findings?.count ?? 0)개") {
                TextField("큰 경로 이름·경로 검색", text: $findingsQuery)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 420)
                LazyVStack(alignment: .leading, spacing: 8) {
                ForEach((b.findings ?? []).filter { findingsQuery.isEmpty || $0.path.localizedCaseInsensitiveContains(findingsQuery) }, id: \.path) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(row.path).font(.callout.monospaced()).textSelection(.enabled)
                            Spacer()
                            Text(row.bytes.map { (row.complete ? "" : "최소 ") + size($0) } ?? "미측정").monospacedDigit()
                        }
                        Text("\(row.classification ?? "내용 확인 필요") · \(row.evidence ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("하위 내용 확인") { browse(row.path) }.disabled(busy)
                            if row.cleanupReview == true, let onReviewCleanup {
                                Button("사용·재생성 근거 조사") { onReviewCleanup(row.path) }
                            }
                        }
                        Divider()
                    }.padding(.vertical, 5)
                }
                }
            }
            DisclosureGroup("이전 실측 대비 변화 · \(b.changes?.count ?? 0)개") {
                Text("첫 관측·생성 시각만으로 설치 원인이나 사용자 의도를 단정하지 않습니다. 부모·자식 변화는 중복될 수 있습니다.").font(.caption)
                ForEach(b.changes ?? [], id: \.path) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.path).font(.caption.monospaced()).textSelection(.enabled)
                        Text("\(Date(timeIntervalSince1970: row.previousAt).formatted()) \(size(row.previousBytes)) → 이번 조사 \(size(row.bytes)) · 변화 \(size(row.deltaBytes))")
                            .font(.caption)
                    }.padding(.vertical, 4)
                }
            }
            DisclosureGroup("접근하지 못한 경로 · \(b.accessIssues?.count ?? 0)개") {
                ForEach(Array((b.accessIssues ?? []).prefix(100).enumerated()), id: \.offset) { _, issue in
                    Text("\(issue.path) · \(issue.reason)").font(.caption).textSelection(.enabled)
                }
                if (b.accessIssues?.count ?? 0) > 100 { Text("처음 100개 표시 · 전체 경로는 조사 기록에 저장됩니다.").font(.caption) }
            }
            if let metadata = b.uafMetadata {
                DisclosureGroup("시스템 AI 자산 · 별도 메타데이터 기록") {
                    Text("기록 수정 시각 \(Date(timeIntervalSince1970: metadata.recordedAt).formatted()) · 아래는 논리 크기입니다. 현재 할당량·회수 가능량에 합산하지 않습니다.").font(.caption)
                    ForEach(metadata.rows.sorted { $0.logicalBytes > $1.logicalBytes }, id: \.name) { row in
                        Text("\(row.name) · 논리 크기 \(size(row.logicalBytes))").font(.caption).textSelection(.enabled)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func segmentWidth(_ width:CGFloat,_ bytes:Int64,_ total:Int64)->CGFloat { max(CGFloat(0),width * CGFloat(bytes) / CGFloat(max(total,1)) - 1) }
    private func volumeMap(_ b:DiskBalance)->some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(alignment:.firstTextBaseline) {
                Text(size(b.freeBytes)).font(.system(size:36,weight:.bold,design:.rounded))
                Text(L10n.text("여유")).foregroundStyle(.secondary)
                Spacer(); Text(L10n.text("전체 ") + size(b.totalBytes)).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                HStack(spacing:1) {
                    ForEach(Array(b.volumes.enumerated()),id:\.offset) { i,v in
                        Rectangle().fill(colors[i % colors.count]).frame(width:segmentWidth(geo.size.width,v.bytes,b.totalBytes)).help(L10n.text(v.name) + " " + size(v.bytes))
                    }
                    Rectangle().fill(Color.secondary.opacity(0.12))
                }.clipShape(RoundedRectangle(cornerRadius:10))
            }.frame(height:42)
            LazyVGrid(columns:[GridItem(.adaptive(minimum:150),alignment:.leading)],alignment:.leading,spacing:12) {
                ForEach(Array(b.volumes.enumerated()),id:\.offset) { i,v in
                    HStack(spacing:8) { RoundedRectangle(cornerRadius:3).fill(colors[i % colors.count]).frame(width:10,height:24); VStack(alignment:.leading,spacing:3) { Text(L10n.text(v.name)).font(.caption); Text(size(v.bytes)).font(.callout.weight(.semibold)) } }
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
                Text(item.bytes.map { (item.complete ? "" : L10n.text("최소 ")) + size($0) } ?? L10n.text("미측정")).font(.system(size:23,weight:.semibold,design:.rounded))
                if let classification = item.classification {
                    Text(L10n.text(classification)).font(.caption.weight(.semibold))
                    Text(L10n.text(item.evidence ?? "")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                if let n=item.bytes { ProgressView(value:Double(n),total:Double(maxBytes)).tint(color) }
                else { Label(L10n.text("접근·측정 확인 필요"),systemImage:"questionmark.circle").font(.caption).foregroundStyle(.orange) }
            }.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(color.opacity(0.06),in:RoundedRectangle(cornerRadius:16)).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(busy).help(item.path)
            .contextMenu {
                if item.cleanupReview == true, let onReviewCleanup {
                    Button(L10n.text("정리 후보에서 검토"), action:{ onReviewCleanup(item.path) })
                }
                Button(L10n.text("Finder에서 보기")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:item.path)]) }; Text(item.path) }
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
