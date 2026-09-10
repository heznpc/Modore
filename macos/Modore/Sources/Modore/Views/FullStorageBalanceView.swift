import SwiftUI

private struct DiskBalance: Decodable {
    struct Volume: Decodable { let name: String; let bytes: Int64 }
    struct Directory: Decodable { let name, path: String; let bytes: Int64?; let complete: Bool }
    let observedAt: Double
    let totalBytes, freeBytes: Int64
    let volumes: [Volume]
    let directories: [Directory]
    let warnings: [String]
}
struct FullStorageBalanceView: View {
    @EnvironmentObject private var model: ScanModel
    @State private var balance: DiskBalance?
    @State private var busy = false
    @State private var error = ""
    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment:.leading,spacing:4) {
                        Text("이 디스크 전체").font(.title2.bold())
                        Text("전체 사용량을 먼저 보고, 정리 탭에서 삭제할 항목을 선택하세요.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("전체 다시 측정") { measure(fresh:true) }.disabled(busy)
                }
                if busy { ProgressView("전체 영역 측정 중 · 접근할 수 없는 항목은 별도 표시합니다") }
                if let balance {
                    Text("전체 \(size(balance.totalBytes)) · 사용 \(size(balance.totalBytes-balance.freeBytes)) · 여유 \(size(balance.freeBytes))").font(.headline)
                    ProgressView(value:Double(balance.totalBytes-balance.freeBytes),total:Double(balance.totalBytes))
                    Text("측정 \(Date(timeIntervalSince1970:balance.observedAt).formatted())").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let balance {
                Section("전체 용량 구성 · APFS 실측") {
                    ForEach(balance.volumes,id:\.name) { v in
                        HStack { Text(v.name); Spacer(); Text(size(v.bytes)).monospacedDigit() }
                    }
                    Text("OS·부팅·복구 영역은 재부팅해도 대부분 유지됩니다. VM·스왑은 메모리 사용에 따라 바뀝니다. 마운트된 시뮬레이터 이미지와 외장 SSD는 중복 합산하지 않습니다.").font(.caption).foregroundStyle(.secondary)
                }
                Section("앱·사용자 자료의 위치별 크기") {
                    ForEach(balance.directories,id:\.path) { item in
                        HStack {
                            Label(item.name,systemImage:"folder")
                            Spacer()
                            Text(item.bytes.map { (item.complete ? "" : "최소 ") + size($0) } ?? "미측정").monospacedDigit()
                            Button("열기") { NSWorkspace.shared.open(URL(fileURLWithPath:item.path)) }
                        }
                    }
                    Text("폴더 크기는 파일의 할당량이며 APFS 공유 블록·스냅샷 때문에 물리 사용량과 다를 수 있습니다.").font(.caption).foregroundStyle(.secondary)
                    ForEach(balance.warnings,id:\.self) { Text($0).foregroundStyle(.orange) }
                }
            }
            if !error.isEmpty { Text(error).foregroundStyle(.orange) }
        }.listStyle(.inset).task { measure(fresh:false) }
    }
    private func measure(fresh:Bool) {
        guard !busy else { return };busy=true;error=""
        Task {
            defer { busy=false }
            do {
                let data=try await EnvironmentRetirementService.invoke(root:model.projectRoot,request:["action":"balance","fresh":fresh])
                balance=try JSONDecoder().decode(DiskBalance.self,from:data)
            } catch { self.error=error.localizedDescription }
        }
    }
    private func size(_ b:Int64)->String { ByteCountFormatter.string(fromByteCount:b,countStyle:.file) }
}
