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

    private var inventory: [StorageItem] {
        var paths = Set<String>()
        return (StorageInvestigation.inventory(storage) + (supplemental?.candidates ?? []))
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
                                    Text(group.title).font(.headline)
                                    Text("\(items.count)").font(.callout).foregroundStyle(.secondary)
                                    Spacer()
                                    if group == .ready {
                                        Button("이 그룹 선택") { selectedKeys.formUnion(items.map(SpaceGoalSelection.key)) }
                                            .disabled(model.isBusy)
                                    }
                                }.padding(.vertical, 6)
                                ForEach(items, id: \.investigationKey) { item in
                                    SpaceGoalCandidateRow(item: item, evidence: evidence(item), judgment: group,
                                        scanDate: model.deepScanAt,
                                        isSelected: Binding(get: { selectedKeys.contains(SpaceGoalSelection.key(item)) },
                                            set: { if $0 { selectedKeys.insert(SpaceGoalSelection.key(item)) }
                                                else { selectedKeys.remove(SpaceGoalSelection.key(item)) } }))
                                    if let device = storage.simulatorDevices.first(where: { $0.path == item.path }) {
                                        DisclosureGroup("기기 보존 설정·개별 검토") { WorkspaceSimulatorRow(device: device) }
                                            .font(.caption).padding(.bottom, 8)
                                    }
                                    Divider()
                                }
                            }
                        }
                    }
                    if visible.isEmpty {
                        Text("현재 필터에 해당하는 항목이 없습니다. 조사 범위와 검색어를 확인하세요.")
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
            coverageExpanded = coverage.contains { $0.status != "ok" } || !storage.accessIssues.isEmpty
        }
        .task { supplemental = await Task.detached(priority: .utility) { SupplementalStorageAudit.latest() }.value }
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
                    Text("저장공간 조사").font(.title.bold())
                    Text("조사 → 근거 확인 → 선택 → 재검증 → 결과")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(pending.isEmpty ? "현재 범위 다시 조사" : "미확인 \(pending.count)개 조사") {
                    let items = pending.isEmpty ? investigable : pending
                    selectedKeys.subtract(items.map(SpaceGoalSelection.key))
                    model.investigateStorage(items)
                }.buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || investigable.isEmpty)
            }
            HStack(alignment: .top, spacing: 28) {
                metric("현재 여유", StorageBytes.text(model.liveState.freeSpace?.value.freeBytes
                    ?? (storage.volumeMeasured ? StorageBytes.fromLegacyGiB(storage.freeGB) : nil)),
                    model.liveState.freeSpace.map { "\($0.observedAt.formatted(date: .omitted, time: .standard)) 측정" }
                        ?? (storage.volumeMeasured ? "\(model.deepScanAt?.formatted() ?? "시각 미확인") 검사 기준" : "여유 공간 측정 실패"))
                metric("전체 정리 가능 대상 점유", ready.isEmpty ? (inventory.contains { judgment($0) == .uncertain } ? "조사 필요" : "해당 없음") : StorageBytes.text(bytes(ready)),
                    "실제 확보량은 정리 후 확인")
                metric("현재 범위 조사", "\(investigatedCount) / \(investigable.count)",
                    "확인 부족 \(pending.count)개 · 전체 디스크 아님")
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
            Picker("결과 범위", selection: $filter) {
                ForEach(StorageResultFilter.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).frame(maxWidth: 370)
            TextField("이름·경로 검색", text: $query).textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            Spacer(minLength: 0)
            Text("큰 항목부터").font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var coverageView: some View {
        DisclosureGroup(isExpanded: $coverageExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("경로 발견과 크기 측정은 범위·시간 제한이 있습니다. 목록에 없다고 공간을 차지하지 않는 것은 아닙니다.")
                ForEach(coverage) { source in
                    Text("\(source.label) · \(source.statusText)\n\(source.detail)")
                }
                ForEach(storage.accessIssues) { issue in
                    Text("\(issue.label) · \(issue.path)\n\(issue.note)")
                }
                HStack {
                    Button("경로 목록 다시 검사") { model.runScan() }.disabled(model.isBusy)
                    Button("접근 설정 열기") { model.openFullDiskAccessSettings() }
                }
                StorageSupplementalAuditView(audit: supplemental)
            }.frame(maxWidth: .infinity, alignment: .leading)
                .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8).textSelection(.enabled)
        } label: {
            Text("조사 범위 · 누락·접근 문제 \(coverage.filter { $0.status != "ok" }.count + storage.accessIssues.count)건 · \(model.deepScanAt?.formatted(date: .abbreviated, time: .shortened) ?? "검사 시각 미확인")")
                .font(.callout.weight(.medium))
        }
    }

    private var optionsAndHistory: some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup("추가 확보 목표 · 선택 기능") {
                HStack {
                    Toggle("목표에 도달하면 남은 항목 보존", isOn: $goalEnabled)
                    Stepper("\(Int(targetGiB)) GiB", value: $targetGiB, in: 1...max(2, storage.totalGB), step: 1)
                        .fixedSize().disabled(!goalEnabled)
                }.padding(.vertical, 8).disabled(model.isBusy)
            }
            if let report = recovery.last {
                DisclosureGroup("과거 자동 정리 · \(report.date.formatted(date: .abbreviated, time: .shortened))") {
                    Text(AutomaticCacheRecovery.summary(report)).font(.caption).foregroundStyle(.secondary)
                    AutomaticRecoveryDetails(report: report)
                }
            }
            if !model.recoveryHistory.isEmpty {
                DisclosureGroup("이전 선택·정리 결과") { RecoveryHistorySection() }
            }
        }.font(.callout)
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress = model.storageInvestigationProgress ?? model.cleanupRecoveryProgress, model.cleanupRecoveryPlan == nil {
                HStack {
                    ProgressView(value: progress.fraction).frame(width: 150)
                    Text("\(progress.currentLabel) · \(progress.completedCount)/\(progress.totalCount)").font(.caption)
                    Spacer()
                    Button("조사 중지") { model.cancelCleanupPreviewRequest() }
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("선택 \(selection.count)개 · 대상 점유 \(StorageBytes.text(bytes(selection)))").fontWeight(.medium)
                        Text("모든 필터의 선택 포함 · 선택 항목의 현재 상태를 다시 확인합니다")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !selection.isEmpty { Button("선택 해제") { selectedKeys.removeAll() } }
                    Button("선택 항목 재검증") {
                        model.prepareRecoveryPlan(selection,
                            requestedGainBytes: StorageBytes.fromLegacyGiB(targetGiB) ?? StorageBytes.perGiB,
                            stopAtGoal: goalEnabled)
                    }.buttonStyle(.borderedProminent).disabled(model.isBusy || selection.isEmpty)
                }
            }
        }.padding(16)
    }
}
