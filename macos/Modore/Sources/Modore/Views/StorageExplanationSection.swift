import SwiftUI

private struct StorageExplanation: Decodable {
    struct Row: Decodable, Identifiable {
        struct Candidate: Decodable, Identifiable {
            var id: String { path }
            let path: String
            let createdBytes: Int64
            let modifiedBytes: Int64
        }
        var id: String { path }
        let label: String
        let path: String
        let allocatedBytes: Int64
        let createdBytes: Int64
        let modifiedBytes: Int64
        let measuredDeltaBytes: Int64?
        let recentDeltaBytes: Int64?
        let previousMeasuredAt: String?
        let complete: Bool
        let errors: Int
        let candidates: [Candidate]?
    }
    let capturedAt: String
    let since: String
    let freeDropBytes: Int64?
    let freeBytes: Int64
    let rows: [Row]
    let interpretation: String
}

struct StorageExplanationSection: View {
    @EnvironmentObject private var model: ScanModel
    @State private var report: StorageExplanation?
    @State private var running = false
    @State private var error: String?
    @State private var progress = ""

    private func bytes(_ value: Int64) -> String {
        StorageBytes.text(value)
    }

    var body: some View {
        Section {
            HStack {
                Text(L10n.text("공간 확보 이후 무엇이 생겼나")).font(.headline)
                Spacer()
                Button(running ? L10n.text("원인 측정 중…") : L10n.text("증가 원인 분석")) {
                    model.startTrackedApplicationTask { await refresh() }
                }.disabled(running)
            }
            if running {
                ProgressView(progress.isEmpty ? L10n.text("파일 메타데이터 측정 중…") : progress)
            }
            if let error { Text(error).foregroundStyle(.secondary).textSelection(.enabled) }
            if let report {
                Text(L10n.format("비교 시작: %@ · 측정: %@", String(describing: report.since), String(describing: report.capturedAt)))
                    .font(.caption).foregroundStyle(.secondary)
                if let drop = report.freeDropBytes {
                    Text(L10n.format("여유 공간 감소 %@ · 측정 당시 여유 %@", String(describing: bytes(drop)), String(describing: bytes(report.freeBytes))))
                        .font(.callout.weight(.semibold))
                }
                Text(L10n.message(report.interpretation)).font(.caption).foregroundStyle(.secondary)
                ForEach(report.rows) { row in
                    DisclosureGroup {
                        Text(row.path).font(.caption.monospaced()).textSelection(.enabled)
                        Text(L10n.format("현재 점유 %@ · 기존 파일 중 수정 흔적 %@", String(describing: bytes(row.allocatedBytes)), String(describing: bytes(row.modifiedBytes))))
                        if let delta = row.measuredDeltaBytes {
                            Text(L10n.format("기준 시점 실측 대비 변화 %@", String(describing: bytes(delta))))
                        } else {
                            Text(L10n.text("기준 시점 실측 없음: 생성 흔적을 원인 후보로 표시합니다."))
                        }
                        if let recent = row.recentDeltaBytes, let at = row.previousMeasuredAt {
                            Text(L10n.format("최근 실측(%@) 대비 %@", String(describing: at), String(describing: bytes(recent))))
                        }
                        if !row.complete { Text(L10n.format("접근·측정 실패 %@건: 부분 결과", String(describing: row.errors))) }
                        if let candidates = row.candidates, !candidates.isEmpty {
                            DisclosureGroup(L10n.format("실제 증가 원인 후보 경로 %@개", String(describing: candidates.count))) {
                                ForEach(candidates) { candidate in
                                    VStack(alignment: .leading) {
                                        Text(candidate.path).font(.caption.monospaced()).textSelection(.enabled)
                                        Text(L10n.format("이후 생성 파일 %@ · 수정된 기존 파일 %@", String(describing: bytes(candidate.createdBytes)), String(describing: bytes(candidate.modifiedBytes))))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text(L10n.message(row.label))
                            Spacer()
                            Text(L10n.format("이후 생성 %@", String(describing: bytes(row.createdBytes)))).monospacedDigit()
                        }
                    }
                }
            } else if !running {
                Text(L10n.text("기록이 없는 기간도 현재 남아 있는 파일의 생성·수정 흔적으로 조사합니다."))
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            let url = StorageHistoryStore.stateDirectory.appendingPathComponent("storage-explanation.json")
            report = await Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: url) else { return nil as StorageExplanation? }
                return try? JSONDecoder().decode(StorageExplanation.self, from: data)
            }.value
        }
    }

    @MainActor private func refresh() async {
        guard !running else { return }
        running = true; error = nil; progress = ""
        let monitor = Task {
            while !Task.isCancelled {
                let url = StorageHistoryStore.stateDirectory.appendingPathComponent("storage-explanation-progress.json")
                if let data = try? Data(contentsOf: url),
                   let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let count = value["completed"] as? Int, let total = value["total"] as? Int,
                   let label = value["label"] as? String {
                    progress = L10n.format("%@/%@ 경로 측정 · %@", String(describing: count), String(describing: total), String(describing: label))
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        defer { running = false; monitor.cancel() }
        do {
            let result = try await StorageAttributionService.run()
            report = try JSONDecoder().decode(StorageExplanation.self, from: JSONEncoder().encode(result))
        } catch {
            self.error = L10n.format("원인 분석 결과를 읽지 못했습니다: %@", String(describing: error.localizedDescription))
        }
    }
}
