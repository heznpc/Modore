import SwiftUI

struct BuildArtifactLifecycleView: View {
    @EnvironmentObject private var model: ScanModel
    @StateObject private var service = BuildArtifactLifecycleService()
    @State private var query = ""
    @State private var reviewedItems: [BuildArtifactReport.Item] = []
    @State private var approvalOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("빌드 산출물 보관·회수")).font(.title.bold())
                    Text(L10n.text("생성 → 검증 종료 → 설치본 연결 → 보관 또는 회수")).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("새로 확인")) { Task { await service.refresh(model: model) } }
                    .disabled(service.busy || model.isBusy)
                Button(L10n.format("전체 회수 가능 %d개 검토", service.report?.items.filter(\.eligible).count ?? 0)) {
                    reviewedItems = service.report?.items.filter(\.eligible) ?? []
                    approvalOpen = true
                }
                    .disabled(service.busy || model.isBusy || model.cleanupReviewOnly || service.report?.items.contains(where: \.eligible) != true)
            }
            CleanupReviewOnlyNotice()
            if service.busy { ProgressView(L10n.text("생성 기록·현재 사용·보관 조건을 확인하고 있습니다…")) }
            if let error = service.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if let report = service.report {
                Text("\(service.error == nil ? L10n.text("마지막 확인") : L10n.text("이전 확인 결과")) · \(Date(timeIntervalSince1970: report.observedAt).formatted())")
                    .font(.caption).foregroundStyle(.secondary)
                Text(report.policy).font(.callout)
                Text(L10n.format("공용 Python 캐시: %@", (report.sharedCache as NSString).abbreviatingWithTildeInPath))
                    .font(.caption.monospaced()).textSelection(.enabled)
                Text(L10n.text("성공한 빌드·테스트는 종료 시 회수 조건을 검사합니다. 기록이 없는 과거 폴더는 자동 삭제하지 않습니다."))
                    .font(.caption).foregroundStyle(.secondary)
                TextField(L10n.text("경로·보존 사유 검색"), text: $query).textFieldStyle(.roundedBorder)
                List(report.items.filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) || $0.reason.localizedCaseInsensitiveContains(query) }) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top) {
                            Text((item.path as NSString).abbreviatingWithTildeInPath).font(.callout.monospaced()).textSelection(.enabled)
                            Spacer()
                            if let bytes = item.bytes { Text(L10n.format("기록 당시 %@", StorageBytes.text(bytes))).font(.caption) }
                        }
                        Text(item.reason).fontWeight(.medium).foregroundStyle(item.eligible ? .green : .secondary)
                        if item.startedAt > 0 {
                            Text(L10n.format("생성 %@ · 종료 %@", Date(timeIntervalSince1970: item.startedAt).formatted(), item.finishedAt.map { Date(timeIntervalSince1970: $0).formatted() } ?? L10n.text("미확인")))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !item.validation.isEmpty { Text(item.validation).font(.caption) }
                        ForEach(item.installedPaths, id: \.self) { Text(L10n.format("서명으로 연결한 설치본: %@", $0)).font(.caption).textSelection(.enabled) }
                        ForEach(item.previousInstalledPaths, id: \.self) { Text(L10n.format("이전 연결 · 현재 서명 변경 또는 경로 없음: %@", $0)).font(.caption).foregroundStyle(.secondary) }
                        if item.kind == "app" && item.installedPaths.isEmpty {
                            Button(L10n.text("설치본 연결 확인")) { Task { await service.connectInstalled(item, model: model) } }
                                .disabled(service.busy)
                        }
                    }.padding(.vertical, 6)
                }
                if report.items.isEmpty { Text(L10n.text("아직 등록된 빌드가 없습니다. 다음 관리 빌드부터 생성·검증·보관 기록이 남습니다.")).foregroundStyle(.secondary) }
            }
        }.padding(20).task { await service.refresh(model: model) }
        .sheet(isPresented: $approvalOpen) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.format("검증 완료 산출물 %d개 삭제 검토", reviewedItems.count)).font(.title2.bold())
                Text(L10n.text("검색 필터와 관계없이 아래 전체 대상을 검토합니다. 실행 직전에 내용·사용 여부를 다시 검사하며 조건이 바뀐 항목은 보존합니다."))
                Text(L10n.format("기록된 대상 점유 %@", StorageBytes.text(reviewedItems.compactMap(\.bytes).reduce(0, +))))
                List(reviewedItems) { item in
                    VStack(alignment: .leading) {
                        Text((item.path as NSString).abbreviatingWithTildeInPath).textSelection(.enabled)
                        Text(item.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                CleanupReviewOnlyNotice()
                HStack {
                    Button(L10n.text("취소")) { approvalOpen = false }
                    Spacer()
                    Button(L10n.format("검토한 %d개 삭제", reviewedItems.count), role: .destructive) {
                        let identifiers = reviewedItems.map(\.id)
                        approvalOpen = false
                        Task { await service.refresh(model: model, reclaim: true, identifiers: identifiers) }
                    }.disabled(model.cleanupReviewOnly || model.isBusy || service.busy)
                }
            }.padding(24).frame(width: 640, height: 460)
        }
    }
}
