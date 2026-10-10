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
        ByteCountFormatter.string(fromByteCount: value, countStyle: .decimal)
    }

    var body: some View {
        Section {
            HStack {
                Text(L10n.text("공간 확보 이후 무엇이 생겼나")).font(.headline)
                Spacer()
                Button(running ? L10n.text("원인 측정 중…") : L10n.text("증가 원인 분석")) {
                    Task { await refresh() }
                }.disabled(running)
            }
            if running {
                ProgressView(progress.isEmpty ? L10n.text("파일 메타데이터 측정 중…") : progress)
            }
            if let error { Text(error).foregroundStyle(.secondary).textSelection(.enabled) }
            if let report {
                Text(L10n.format("비교 시작: %@ · 측정: %@", report.since, report.capturedAt))
                    .font(.caption).foregroundStyle(.secondary)
                if let drop = report.freeDropBytes {
                    Text(L10n.format("여유 공간 감소 %@ · 측정 당시 여유 %@", bytes(drop), bytes(report.freeBytes)))
                        .font(.callout.weight(.semibold))
                }
                Text(report.interpretation).font(.caption).foregroundStyle(.secondary)
                ForEach(report.rows) { row in
                    DisclosureGroup {
                        Text(row.path).font(.caption.monospaced()).textSelection(.enabled)
                        Text(L10n.format("현재 점유 %@ · 기존 파일 중 수정 흔적 %@", bytes(row.allocatedBytes), bytes(row.modifiedBytes)))
                        if let delta = row.measuredDeltaBytes {
                            Text(L10n.format("기준 시점 실측 대비 변화 %@", bytes(delta)))
                        } else {
                            Text(L10n.text("기준 시점 실측 없음: 생성 흔적을 원인 후보로 표시합니다."))
                        }
                        if let recent = row.recentDeltaBytes, let at = row.previousMeasuredAt {
                            Text(L10n.format("최근 실측(%@) 대비 %@", at, bytes(recent)))
                        }
                        if !row.complete { Text(L10n.format("접근·측정 실패 %@건: 부분 결과", String(row.errors))) }
                        if let candidates = row.candidates, !candidates.isEmpty {
                            DisclosureGroup(L10n.format("실제 증가 원인 후보 경로 %@개", String(candidates.count))) {
                                ForEach(candidates) { candidate in
                                    VStack(alignment: .leading) {
                                        Text(candidate.path).font(.caption.monospaced()).textSelection(.enabled)
                                        Text(L10n.format("이후 생성 파일 %@ · 수정된 기존 파일 %@", bytes(candidate.createdBytes), bytes(candidate.modifiedBytes)))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text(row.label)
                            Spacer()
                            Text(L10n.format("이후 생성 %@", bytes(row.createdBytes))).monospacedDigit()
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
                    progress = L10n.format("%@/%@ 경로 측정 · %@", String(count), String(total), label)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        defer { running = false; monitor.cancel() }
        let root = model.projectRoot
        guard let execution = await Task.detached(priority: .utility, operation: {
            RuntimeWorkspace.prepareExecution(projectRoot: root)
        }).value,
        let invocation = execution.pinnedInvocation(relativePath: "scripts/storage_explain.py", name: "storage_explain"),
        let python = ScreeService.python3Path(signedBundleURL: execution.signedBundleURL) else {
            error = L10n.text("저장공간 원인 분석 실행환경을 준비하지 못했습니다."); return
        }
        let wrapper = "import sys; source=open(sys.argv[1],'rb').read(); sys.argv=['storage_explain.py']; exec(compile(source,'storage_explain.py','exec'),{'__name__':'__main__'})"
        let result = await LocalProcessRunner.capture(executable: python,
            arguments: ["-I", "-B", "-c", wrapper, invocation.argument],
            currentDirectory: execution.runtimeRoot, expectedCurrentDirectoryIdentity: execution.runtimeRootIdentity,
            expectedSignedBundleURL: execution.signedBundleURL, pinnedFiles: invocation.files,
            timeout: 1800, maxOutputBytes: 8_000_000, waitForCleanupOnStop: true)
        guard result.succeeded else {
            error = L10n.format("원인 분석을 끝내지 못했습니다: %@. 이전 결과를 유지합니다.", String(result.status)); return
        }
        do { report = try JSONDecoder().decode(StorageExplanation.self, from: Data(result.output.utf8)) }
        catch { self.error = L10n.format("원인 분석 결과를 읽지 못했습니다: %@", error.localizedDescription) }
    }
}
