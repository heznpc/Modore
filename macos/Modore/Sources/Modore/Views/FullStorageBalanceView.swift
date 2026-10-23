import SwiftUI

struct DiskBalance: Decodable, Sendable {
    struct Volume: Decodable, Sendable { let name: String; let bytes: Int64 }
    struct Directory: Decodable, Sendable, Identifiable { var id: String { path }; let name, path: String; let bytes: Int64?; let complete: Bool; var directory: Bool?; var classification: String?; var evidence: String?; var cleanupReview: Bool? }
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
                "note": L10n.format("전체 볼륨 조사에서 발견 · %@ · 현재 크기·사용 여부 재검증 필요", String(describing: Date(timeIntervalSince1970: observedAt).formatted()))])
        }
    }
}
private struct DirectoryBalance: Decodable { let path:String; let observedAt:Double; let entries:[DiskBalance.Directory] }
struct FullStorageBalanceView: View {
    var onReviewCleanup: ((String) -> Void)? = nil
    @EnvironmentObject private var model: ScanModel
    @State private var balance: DiskBalance?
    @State private var folder: DirectoryBalance?
    private var busy: Bool { model.storageMeasurementInFlight }
    @State private var error = ""
    @State private var query = ""
    @State private var findingsQuery = ""
    @State private var appDuplicates = false
    @State private var workbench = false
    @State private var selectedPath: String?
    @State private var showingInspector = false
    @State private var showingEvidence = false
    private let colors: [Color] = [.blue, .blue.opacity(0.65), .secondary.opacity(0.5), .secondary.opacity(0.3)]
    private var selectedDirectory: DiskBalance.Directory? { entries.first { $0.path == selectedPath } }
    private var entries:[DiskBalance.Directory] { (folder?.entries ?? balance?.directories ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) } }
    var body: some View {
        VStack(spacing: 0) {
            if let balance {
                volumeMap(balance).padding(22)
            } else if !busy {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("저장된 공간 지도가 없습니다. 전체 측정을 시작하면 폴더별 사용량을 확인합니다."))
                        .foregroundStyle(.secondary)
                    Button(L10n.text("전체 측정 시작")) { measure() }.modoreGlassButton(prominent: true).disabled(model.isBusy)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
            HStack(spacing: 10) {
                Button { folder = nil; query = ""; selectedPath = nil } label: {
                    Label(L10n.text("내부 디스크"), systemImage: "internaldrive")
                }.buttonStyle(.plain).disabled(model.isBusy)
                if let folder {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    Text(URL(fileURLWithPath: folder.path).lastPathComponent).lineLimit(1)
                    Button(L10n.text("상위 폴더")) { browse(URL(fileURLWithPath: folder.path).deletingLastPathComponent().path) }.disabled(model.isBusy)
                }
                Spacer()
                TextField(L10n.text("이름으로 찾기"), text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
            }.padding(.horizontal, 22).padding(.bottom, 16)
            if busy {
                HStack { ProgressView().controlSize(.small); Text(L10n.text("용량 측정 중")); Spacer(); Button(L10n.text("측정 중지")) { model.cancelStorageScreenTasks() } }
                    .padding(.horizontal, 22).padding(.bottom, 12)
            }
            Table(entries, selection: $selectedPath) {
                TableColumn(L10n.text("항목")) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.directory == false ? "doc" : "folder").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).fontWeight(.medium).lineLimit(1)
                            if let classification = item.classification {
                                Text(L10n.message(classification)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.padding(.vertical, 9)
                    }.help(item.path)
                }.width(min: 130, ideal: 260)
                TableColumn(L10n.text("크기")) { item in
                    Text(item.bytes.map(size) ?? L10n.text("미측정")).monospacedDigit()
                }.width(min: 75, ideal: 95, max: 115)
                TableColumn(L10n.text("측정 상태")) { item in
                    Text(item.bytes == nil ? L10n.text("미측정") : item.complete ? L10n.text("측정 완료") : L10n.text("최소 · 일부 접근 제한"))
                        .font(.caption).foregroundStyle(.secondary)
                }.width(min: 135, ideal: 150, max: 180)
            }
            if !error.isEmpty { Label(L10n.message(error), systemImage: "exclamationmark.circle").foregroundStyle(.orange).padding(12) }
            Text(L10n.text("폴더 크기 = 파일 할당량 · 최소 = 일부 접근 제한 · 미측정 ≠ 0 · APFS 공유 블록 때문에 위 물리 용량과 합계가 다를 수 있습니다."))
                .font(.caption).foregroundStyle(.secondary).padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .modoreStaticScrollEdges()
        .modoreInspector(isPresented: $showingInspector) { directoryInspector }
        .onChange(of: selectedPath) { value in showingInspector = value != nil }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { folder = nil; selectedPath = nil; measure() } label: {
                    Label(balance == nil ? L10n.text("전체 측정 시작") : L10n.text("전체 다시 측정"), systemImage: "arrow.clockwise")
                }.disabled(model.isBusy)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(L10n.text("근거 상세")) { showingInspector.toggle() }.disabled(selectedDirectory == nil)
                    Button(L10n.text("측정 근거")) { showingEvidence = true }.disabled(balance == nil)
                    Button(L10n.text("앱 중복 찾기")) { appDuplicates = true }
                    Button(L10n.text("개발 환경 정리")) { workbench = true }
                } label: { Label(L10n.text("도구"), systemImage: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showingEvidence) {
            VStack(alignment: .trailing) {
                Button(L10n.text("닫기")) { showingEvidence = false }
                ScrollView { if let balance { investigationSummary(balance).padding(8) } }
            }.padding(24).frame(width: 730, height: 600)
        }
        .task {
            let cached = await Task.detached(priority: .utility) { DiskBalance.latest() }.value
            guard !Task.isCancelled else { return }
            balance = cached
        }
        .onDisappear { model.cancelStorageScreenTasks() }
        .navigationDestination(isPresented: $appDuplicates) { EnvironmentRetirementView(initialTab: "apps") }
        .navigationDestination(isPresented: $workbench) { EnvironmentRetirementView() }
    }

    @ViewBuilder private var directoryInspector: some View {
        if let item = selectedDirectory {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Image(systemName: item.directory == false ? "doc" : "folder").font(.largeTitle).foregroundStyle(.secondary)
                        Spacer()
                        Button { showingInspector = false } label: { Label(L10n.text("닫기"), systemImage: "xmark") }
                            .labelStyle(.iconOnly).modoreGlassButton()
                    }
                    Text(item.name).font(.title3.weight(.semibold))
                    Text(item.bytes.map { (item.complete ? "" : L10n.text("최소 ")) + size($0) } ?? L10n.text("미측정")).font(.title2).monospacedDigit()
                    Divider()
                    Text(item.path).font(.caption.monospaced()).textSelection(.enabled)
                    if let classification = item.classification { Text(L10n.message(classification)).fontWeight(.medium) }
                    if let evidence = item.evidence { Text(L10n.message(evidence)).foregroundStyle(.secondary) }
                    if item.directory != false {
                        Button(L10n.text("하위 내용 확인")) { browse(item.path) }.disabled(model.isBusy)
                    }
                    Button(L10n.text("Finder에서 보기")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
                    if item.cleanupReview == true, let onReviewCleanup {
                        Button(L10n.text("정리 후보에서 검토")) { onReviewCleanup(item.path) }.modoreGlassButton(prominent: true)
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else { Text(L10n.text("항목을 선택하세요")).foregroundStyle(.secondary).padding(24) }
    }
    private func investigationSummary(_ b: DiskBalance) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let allocated = b.scannedAllocatedBytes {
                Text(L10n.format("Data 볼륨 %@ · 파일 할당량 %@%@ · 미설명 차이 %@", String(describing: b.dataVolumeBytes.map(size) ?? L10n.text("미측정")), String(describing: b.scanStatus == "complete" ? "" : L10n.text("최소 ")), String(describing: size(allocated)), String(describing: b.accountingDifferenceBytes.map(size) ?? L10n.text("미측정"))))
                    .font(.callout.weight(.semibold))
            }
            Text(b.scanStatus == "complete" ? L10n.text("전체 순회 완료 · 아래 범위·회계 차이 확인 필요") : L10n.text("전체 설명 미완료 · 접근 실패·측정 범위를 확인하세요"))
                .foregroundStyle(.secondary)
            ForEach(b.warnings, id: \.self) { Text(L10n.message($0)).font(.caption).foregroundStyle(.secondary) }
            if b.scanStatus == nil {
                Text(L10n.text("이전 방식의 기록입니다. 전체 다시 측정을 실행하면 알려진 캐시 목록 밖의 큰 경로도 조사합니다."))
                    .font(.callout)
            }
            DisclosureGroup(L10n.format("전체 조사에서 찾은 큰 경로 · %@개", String(describing: b.findings?.count ?? 0))) {
                TextField(L10n.text("큰 경로 이름·경로 검색"), text: $findingsQuery)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 420)
                LazyVStack(alignment: .leading, spacing: 8) {
                ForEach((b.findings ?? []).filter { findingsQuery.isEmpty || $0.path.localizedCaseInsensitiveContains(findingsQuery) }, id: \.path) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(row.path).font(.callout.monospaced()).textSelection(.enabled)
                            Spacer()
                            Text(row.bytes.map { (row.complete ? "" : L10n.text("최소 ")) + size($0) } ?? L10n.text("미측정")).monospacedDigit()
                        }
                        Text("\(L10n.message(row.classification ?? L10n.text("내용 확인 필요"))) · \(L10n.message(row.evidence ?? ""))")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(L10n.text("하위 내용 확인")) { browse(row.path) }.disabled(model.isBusy)
                            if row.cleanupReview == true, let onReviewCleanup {
                                Button(L10n.text("사용·재생성 근거 조사")) { onReviewCleanup(row.path) }
                            }
                        }
                        Divider()
                    }.padding(.vertical, 5)
                }
                }
            }
            DisclosureGroup(L10n.format("이전 실측 대비 변화 · %@개", String(describing: b.changes?.count ?? 0))) {
                Text(L10n.text("첫 관측·생성 시각만으로 설치 원인이나 사용자 의도를 단정하지 않습니다. 부모·자식 변화는 중복될 수 있습니다.")).font(.caption)
                ForEach(b.changes ?? [], id: \.path) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.path).font(.caption.monospaced()).textSelection(.enabled)
                        Text(L10n.format("%@ %@ → 이번 조사 %@ · 변화 %@", String(describing: Date(timeIntervalSince1970: row.previousAt).formatted()), String(describing: size(row.previousBytes)), String(describing: size(row.bytes)), String(describing: size(row.deltaBytes))))
                            .font(.caption)
                    }.padding(.vertical, 4)
                }
            }
            DisclosureGroup(L10n.format("접근하지 못한 경로 · %@개", String(describing: b.accessIssues?.count ?? 0))) {
                ForEach(Array((b.accessIssues ?? []).prefix(100).enumerated()), id: \.offset) { _, issue in
                    Text("\(issue.path) · \(L10n.message(issue.reason))").font(.caption).textSelection(.enabled)
                }
                if (b.accessIssues?.count ?? 0) > 100 { Text(L10n.text("처음 100개 표시 · 전체 경로는 조사 기록에 저장됩니다.")).font(.caption) }
            }
            if let metadata = b.uafMetadata {
                DisclosureGroup(L10n.text("시스템 AI 자산 · 별도 메타데이터 기록")) {
                    Text(L10n.format("기록 수정 시각 %@ · 아래는 논리 크기입니다. 현재 할당량·회수 가능량에 합산하지 않습니다.", String(describing: Date(timeIntervalSince1970: metadata.recordedAt).formatted()))).font(.caption)
                    ForEach(metadata.rows.sorted { $0.logicalBytes > $1.logicalBytes }, id: \.name) { row in
                        Text(L10n.format("%@ · 논리 크기 %@", String(describing: row.name), String(describing: size(row.logicalBytes)))).font(.caption).textSelection(.enabled)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func segmentWidth(_ width:CGFloat,_ bytes:Int64,_ total:Int64)->CGFloat { max(CGFloat(0),width * CGFloat(bytes) / CGFloat(max(total,1)) - 1) }
    private func volumeMap(_ b:DiskBalance)->some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(alignment:.firstTextBaseline) {
                Text(size(b.freeBytes)).font(.system(size:28,weight:.semibold)).monospacedDigit()
                Text(L10n.text("측정 당시 여유")).foregroundStyle(.secondary)
                Spacer(); Text(L10n.text("전체 ") + size(b.totalBytes)).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                HStack(spacing:1) {
                    ForEach(Array(b.volumes.enumerated()),id:\.offset) { i,v in
                        Rectangle().fill(colors[i % colors.count]).frame(width:segmentWidth(geo.size.width,v.bytes,b.totalBytes)).help(L10n.text(v.name) + " " + size(v.bytes))
                    }
                    Rectangle().fill(Color.secondary.opacity(0.12))
                }.clipShape(RoundedRectangle(cornerRadius:10))
            }.frame(height:12)
            LazyVGrid(columns:[GridItem(.adaptive(minimum:150),alignment:.leading)],alignment:.leading,spacing:12) {
                ForEach(Array(b.volumes.enumerated()),id:\.offset) { i,v in
                    HStack(spacing:8) { RoundedRectangle(cornerRadius:3).fill(colors[i % colors.count]).frame(width:7,height:7); VStack(alignment:.leading,spacing:3) { Text(L10n.text(v.name)).font(.caption); Text(size(v.bytes)).font(.callout.weight(.semibold)) } }
                }
            }
                    Text(L10n.text("전체 측정 ") + Date(timeIntervalSince1970: b.observedAt).formatted())
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func browse(_ path: String) {
        runMeasurement(["action": "directory", "path": path]) { data in
            folder = try JSONDecoder().decode(DirectoryBalance.self, from: data)
            query = ""
            selectedPath = nil
            showingInspector = false
        }
    }

    private func measure() {
        runMeasurement(["action": "balance", "fresh": true]) { data in
            balance = try JSONDecoder().decode(DiskBalance.self, from: data)
        }
    }

    private func runMeasurement(_ request: [String: Any], receive: @escaping @MainActor (Data) throws -> Void) {
        model.startStorageMeasurement {
            error = ""
            do {
                let data = try await EnvironmentRetirementService.invoke(root: model.projectRoot, request: request)
                guard !Task.isCancelled, !model.applicationTerminationStarted else { return }
                try receive(data)
            } catch {
                guard !Task.isCancelled, !model.applicationTerminationStarted else { return }
                self.error = error.localizedDescription
            }
        }
    }
    private func size(_ b:Int64)->String { StorageBytes.text(b) }
}
