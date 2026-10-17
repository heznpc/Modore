import AppKit
import SwiftUI

struct SpaceGoalWorkspaceList: View {
    @EnvironmentObject private var model: ScanModel
    @EnvironmentObject private var recovery: AutomaticCacheRecovery
    let storage: StorageSnapshot
    var currentFreeGB: Double? = nil
    var initialFilter: StorageResultFilter = .all
    var initialQuery: String = ""
    @State private var filter: StorageResultFilter = .all
    @State private var selectedKeys = Set<String>()
    @State private var query = ""
    @State private var goalEnabled = false
    @State private var targetGiB = 5.0
    @State private var coverageExpanded = false
    @State private var supplemental: SupplementalStorageAudit?
    @State private var diskBalance: DiskBalance?

    private var inventory: [StorageItem] {
        var paths = Set<String>()
        return (StorageInvestigation.inventory(storage) + (supplemental?.candidates ?? []) + (diskBalance?.candidates ?? []))
            .filter { paths.insert($0.investigationKey).inserted }.sorted {
            let lhs = evidence($0)?.bytes ?? StorageBytes.fromLegacyGiB($0.sizeGB) ?? 0
            let rhs = evidence($1)?.bytes ?? StorageBytes.fromLegacyGiB($1.sizeGB) ?? 0
            return lhs == rhs ? $0.path < $1.path : lhs > rhs
        }
    }
    private func evidence(_ item: StorageItem) -> StorageInvestigation? {
        model.storageInvestigations[SpaceGoalSelection.key(item)]
    }
    private func judgment(_ item: StorageItem) -> StorageJudgment {
        StorageInvestigation.judgment(for: item, evidence: evidence(item))
    }
    private func sourceDate(_ item: StorageItem) -> Date? {
        guard item.measureStatus == "historical" else { return model.deepScanAt }
        if supplemental?.candidatePaths.contains(item.path) == true { return supplemental?.date }
        if let diskBalance, diskBalance.findings?.contains(where: { $0.path == item.path }) == true {
            return Date(timeIntervalSince1970: diskBalance.observedAt)
        }
        return nil
    }
    private var visible: [StorageItem] {
        inventory.filter { filter.includes($0) && (query.isEmpty || $0.label.localizedCaseInsensitiveContains(query)
            || $0.path.localizedCaseInsensitiveContains(query)) }
    }
    private var ready: [StorageItem] { inventory.filter { judgment($0) == .ready } }
    private var selection: [StorageItem] { ready.filter { selectedKeys.contains(SpaceGoalSelection.key($0)) } }
    private var investigable: [StorageItem] { visible.filter(\.hasSupportedCleanupRecipe) }
    private var pending: [StorageItem] { investigable.filter { judgment($0) == .uncertain } }
    private var investigatedCount: Int { investigable.filter { evidence($0) != nil && judgment($0) != .uncertain }.count }
    private func bytes(_ items: [StorageItem]) -> Int64? {
        items.reduce(Optional(Int64(0))) { total, item in
            guard let total, let size = evidence(item)?.bytes else { return nil }
            return StorageBytes.adding(total, size)
        }
    }
    private var coverage: [CollectionSourceStatus] {
        model.collectionCoverage?.sources.filter { $0.id.contains("storage") || $0.id.contains("project") } ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filters
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    coverageView
                    ForEach(StorageJudgment.allCases) { group in
                        let items = visible.filter { judgment($0) == group }
                        if !items.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(L10n.text(group.title)).font(.headline)
                                    Text("\(items.count)").font(.callout).foregroundStyle(.secondary)
                                    Spacer()
                                    if group == .ready {
                                        Button(L10n.text("이 그룹 선택")) { selectedKeys.formUnion(items.map(SpaceGoalSelection.key)) }
                                            .disabled(model.isBusy)
                                    }
                                }.padding(.vertical, 6)
                                ForEach(items, id: \.investigationKey) { item in
                                    SpaceGoalCandidateRow(item: item, evidence: evidence(item), judgment: group,
                                        scanDate: sourceDate(item),
                                        isSelected: Binding(get: { selectedKeys.contains(SpaceGoalSelection.key(item)) },
                                            set: { if $0 { selectedKeys.insert(SpaceGoalSelection.key(item)) }
                                                else { selectedKeys.remove(SpaceGoalSelection.key(item)) } }))
                                    if let device = storage.simulatorDevices.first(where: { $0.path == item.path }) {
                                        DisclosureGroup(L10n.text("기기 보존 설정·개별 검토")) { WorkspaceSimulatorRow(device: device) }
                                            .font(.caption).padding(.bottom, 8)
                                    }
                                    Divider()
                                }
                            }
                        }
                    }
                    if visible.isEmpty {
                        Text(L10n.text("현재 필터에 해당하는 항목이 없습니다. 조사 범위와 검색어를 확인하세요."))
                            .foregroundStyle(.secondary).padding(.vertical, 24)
                    }
                    optionsAndHistory
                }.padding(20)
            }
            Divider()
            actionBar
        }
        .onAppear {
            filter = initialFilter
            query = initialQuery
            // Keep collection evidence available without pushing the task out
            // of view. Its summary still exposes missing/access-limited data.
        }
        .task {
            supplemental = await Task.detached(priority: .utility) { SupplementalStorageAudit.latest() }.value
            diskBalance = await Task.detached(priority: .utility) { DiskBalance.latest() }.value
        }
        .onChange(of: initialFilter) { filter = $0 }
        .onChange(of: initialQuery) { query = $0 }
        .onChange(of: ready.map(SpaceGoalSelection.key).sorted()) { keys in
            selectedKeys.formIntersection(keys)
        }
        .onChange(of: model.reportRevision) { _ in
            selectedKeys = selectedKeys.intersection(Set(ready.map(SpaceGoalSelection.key)))
        }
        .onChange(of: model.cleanupRecoveryResult?.items.count) { _ in
            guard let result = model.cleanupRecoveryResult else { return }
            for item in inventory where result.items.contains(where: {
                $0.recipeID == item.cleanupID && ($0.requestTarget.isEmpty || $0.requestTarget == item.path)
            }) {
                selectedKeys.remove(SpaceGoalSelection.key(item))
                model.storageInvestigations.removeValue(forKey: SpaceGoalSelection.key(item))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("공간 비우기")).font(.title.bold())
                    Text(L10n.text("후보 확인 → 선택 → 정리 내용 확인 → 결과"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("정리 후보 확인")) {
                    selectedKeys.removeAll()
                    model.prepareStorageReview()
                }.buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
            }
            Text(L10n.text("검사와 사용 상태 확인을 함께 진행합니다. 확인 후 정리할 항목을 직접 선택하세요."))
                .font(.callout).foregroundStyle(.secondary)
            CleanupReviewOnlyNotice()
            HStack(alignment: .top, spacing: 28) {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    let current = model.liveState.currentFreeSpace(at: context.date)
                    let observed = current ?? model.liveState.freeSpace
                    metric(current != nil ? L10n.text("실제 여유 공간") : L10n.text("마지막 관찰 · 현재 상태 미확인"),
                        StorageBytes.text(observed?.value.freeBytes
                            ?? (storage.volumeMeasured ? StorageBytes.fromLegacyGiB(storage.freeGB) : nil)),
                        observed.map { L10n.format("%@ 측정", $0.observedAt.formatted(date: .abbreviated, time: .standard)) }
                            ?? (storage.volumeMeasured ? L10n.format("%@ 검사 기준", model.deepScanAt?.formatted() ?? L10n.text("시각 미확인")) : L10n.text("여유 공간 측정 실패")))
                }
                metric(L10n.text("전체 정리 가능 대상 점유"), ready.isEmpty ? (inventory.contains { judgment($0) == .uncertain } ? L10n.text("조사 필요") : L10n.text("해당 없음")) : StorageBytes.text(bytes(ready)),
                    L10n.text("실제 확보량은 정리 후 확인"))
                metric(L10n.text("현재 범위 조사"), "\(investigatedCount) / \(investigable.count)",
                    L10n.format("확인 부족 %@개 · 전체 디스크 아님", String(describing: pending.count)))
                Spacer(minLength: 0)
            }
        }.padding(20)
    }

    private func metric(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var filters: some View {
        HStack(spacing: 16) {
            Picker(L10n.text("결과 범위"), selection: $filter) {
                ForEach(StorageResultFilter.allCases) { Text(L10n.text($0.rawValue)).tag($0) }
            }.pickerStyle(.segmented).frame(maxWidth: 370)
            TextField(L10n.text("이름·경로 검색"), text: $query).textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            Spacer(minLength: 0)
            Text(L10n.text("큰 항목부터")).font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var coverageView: some View {
        DisclosureGroup(isExpanded: $coverageExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("경로 발견과 크기 측정은 범위·시간 제한이 있습니다. 목록에 없다고 공간을 차지하지 않는 것은 아닙니다."))
                ForEach(coverage) { source in
                    Text("\(L10n.message(source.label)) · \(L10n.message(source.statusText))\n\(L10n.message(source.detail))")
                }
                ForEach(storage.accessIssues) { issue in
                    Text("\(L10n.message(issue.label)) · \(issue.path)\n\(L10n.message(issue.note))")
                }
                HStack {
                    Button(L10n.text("정리 후보 확인")) { selectedKeys.removeAll(); model.prepareStorageReview() }.disabled(model.isBusy)
                    Button(L10n.text("접근 설정 열기")) { model.openFullDiskAccessSettings() }
                }
                StorageSupplementalAuditView(audit: supplemental)
            }.frame(maxWidth: .infinity, alignment: .leading)
                .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8).textSelection(.enabled)
        } label: {
            Text(L10n.format("조사 범위 · 누락·접근 문제 %@건 · %@", String(describing: coverage.filter { $0.status != "ok" }.count + storage.accessIssues.count), String(describing: model.deepScanAt?.formatted(date: .abbreviated, time: .shortened) ?? L10n.text("검사 시각 미확인"))))
                .font(.callout.weight(.medium))
        }
    }

    private var optionsAndHistory: some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup(L10n.text("추가 확보 목표 · 선택 기능")) {
                HStack {
                    Toggle(L10n.text("목표에 도달하면 남은 항목 보존"), isOn: $goalEnabled)
                    Stepper("\(Int(targetGiB)) GiB", value: $targetGiB, in: 1...max(2, storage.totalGB), step: 1)
                        .fixedSize().disabled(!goalEnabled)
                }.padding(.vertical, 8).disabled(model.isBusy)
            }
            if let report = recovery.last {
                DisclosureGroup(L10n.format("과거 자동 정리 · %@", String(describing: report.date.formatted(date: .abbreviated, time: .shortened)))) {
                    Text(L10n.message(AutomaticCacheRecovery.summary(report))).font(.caption).foregroundStyle(.secondary)
                    AutomaticRecoveryDetails(report: report)
                }
            }
            if !model.recoveryHistory.isEmpty {
                DisclosureGroup(L10n.text("이전 선택·정리 결과")) { RecoveryHistorySection() }
            }
        }.font(.callout)
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isRunning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("정리할 경로를 찾고 있습니다. 완료되면 사용 상태를 자동으로 확인합니다."))
                        .font(.callout)
                    Spacer()
                    Button(L10n.text("확인 중지")) { model.cancelScan() }
                }
            } else if let progress = model.storageInvestigationProgress ?? model.cleanupRecoveryProgress, model.cleanupRecoveryPlan == nil {
                HStack {
                    ProgressView(value: progress.fraction).frame(width: 150)
                    Text("\(L10n.message(progress.currentLabel)) · \(progress.completedCount)/\(progress.totalCount)").font(.caption)
                    Spacer()
                    Button(L10n.text("조사 중지")) { model.cancelCleanupPreviewRequest() }
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.format("선택 %@개 · 대상 점유 %@", String(describing: selection.count), String(describing: StorageBytes.text(bytes(selection))))).fontWeight(.medium)
                        Text(L10n.text("다음 화면에서 현재 상태와 정리 영향을 확인한 뒤 승인합니다"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !selection.isEmpty { Button(L10n.text("선택 해제")) { selectedKeys.removeAll() } }
                    Button(L10n.text("정리 내용 확인")) {
                        model.prepareRecoveryPlan(selection,
                            requestedGainBytes: StorageBytes.fromLegacyGiB(targetGiB) ?? StorageBytes.perGiB,
                            stopAtGoal: goalEnabled)
                    }.buttonStyle(.borderedProminent).disabled(model.isBusy || selection.isEmpty)
                }
            }
        }.padding(16)
    }
}
