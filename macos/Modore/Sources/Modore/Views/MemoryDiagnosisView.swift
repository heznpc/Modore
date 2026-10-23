import AppKit
import SwiftUI

struct MemoryDiagnosisView: View {
    @State private var diagnosis: MemoryDiagnosis?
    @State private var previous: MemoryDiagnosis?
    @State private var busy = false
    @State private var selectedAppPID: Int32?
    @State private var showApps = false
    @State private var showResources = false
    @State private var showServers = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L10n.text("앱·작업별 메모리 합계")).font(.title2.bold())
                Spacer()
                Button(L10n.text("조치 후 다시 측정")) { refresh() }.disabled(busy)
            }
            if busy { ProgressView(L10n.text("앱과 자식 프로세스를 함께 측정합니다…")) }
            if let diagnosis {
                Text(diagnosis.snapshot.summary).font(.headline)
                Text(L10n.format("물리 RAM %@ · 압축 메모리 %@ · 관찰 %@",
                    bytes(diagnosis.physicalMemory), bytes(diagnosis.snapshot.compressedBytes), diagnosis.snapshot.date.formatted()))
                    .font(.callout).foregroundStyle(.secondary)
                Text(L10n.text("스왑은 RAM에서 밀려난 데이터를 담는 시스템 공간입니다. 아래 큰 작업의 사용을 줄여 RAM 압박부터 낮추세요. 스왑 파일 직접 삭제나 캐시 정리로 해결하지 않습니다. 작업 종료 후에도 이미 할당된 공간은 즉시 줄지 않을 수 있습니다."))
                    .font(.callout)
                if let previous {
                    Text(diagnosis.snapshot.change(from: previous.snapshot)).font(.headline)
                    Text(L10n.text("아래 이전 측정 대비 변화는 같은 PID와 시작 시각인 작업만 비교합니다. 다른 작업의 영향도 포함됩니다."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(diagnosis.families.prefix(12)) { family in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(family.title).font(.headline)
                            Spacer()
                            Text(bytes(family.bytes)).font(.title3.bold()).monospacedDigit()
                        }
                        HStack {
                            Text(L10n.format("프로세스 %@개 합산", String(family.members.count)))
                            if let old = previous?.families.first(where: { $0.id == family.id && $0.root.started == family.root.started }) {
                                Text((family.bytes >= old.bytes ? "+" : "−") + bytes(family.bytes >= old.bytes ? family.bytes - old.bytes : old.bytes - family.bytes))
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                        if family.fallbackCount > 0 { Text(L10n.text("일부 프로세스는 실제 점유량 대신 상주 메모리 사용")).font(.caption).foregroundStyle(.secondary) }
                        if let workspace = family.workspace {
                            Text(workspace).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let accumulation = family.toolAccumulation {
                            Label(L10n.format("여러 시점에 시작한 도구 %@개가 실행 중 · %@", String(accumulation.processCount), bytes(accumulation.bytes)), systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.orange)
                            Text(L10n.text("앱 안의 작업을 확인한 뒤 아래에서 재시작을 검토하세요. 시작 시각만으로 작업 종료를 판별할 수 없어 자동 종료하지 않습니다."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if family.members.count > 1 {
                            ForEach(family.components.prefix(4)) { component in
                                HStack {
                                    Text(component.name + " × " + String(component.count))
                                    Spacer()
                                    Text(bytes(component.bytes))
                                }.font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        if let app = NSRunningApplication(processIdentifier: family.id), app.activationPolicy == .regular,
                           family.id != ProcessInfo.processInfo.processIdentifier {
                            HStack {
                                Button(L10n.text("작업 확인")) { if NativeCPUReader.read(family.id)?.started == family.root.started { app.activate(options: [.activateIgnoringOtherApps]) } }
                                Button(L10n.text("재시작 검토…")) { selectedAppPID = family.id; showApps = true }
                            }
                        } else if family.root.name == "launchd_sim" {
                            Button(L10n.text("기기 확인·실행만 종료…")) { showResources = true }
                        } else if ["node", "node_repl", "bun", "python", "python3", "python3.11"].contains(family.root.name) {
                            Button(L10n.text("서버·작업 종료 검토…")) { showServers = true }
                        }
                        DisclosureGroup(L10n.text("포함된 프로세스")) {
                            ForEach(family.members.prefix(8), id: \.pid) { process in
                                HStack { Text("\(process.name) · PID \(process.pid)"); Spacer(); Text(bytes(process.bytes)) }
                                    .font(.caption).textSelection(.enabled)
                            }
                            if family.members.count > 8 { Text(L10n.text("메모리 상위 8개 표시 · 합계에는 전체 포함")).font(.caption) }
                        }
                    }.padding(16).background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                }
                Text(L10n.format("조회 가능 %@ / 전체 %@개 프로세스. 접근 제한·종료된 프로세스는 제외합니다. 합계는 관찰 가능한 부모·자식 관계 기준이며 세션 소유권이나 누수의 증명은 아닙니다. 공유 메모리는 중복될 수 있습니다.",
                    String(diagnosis.readableProcesses), diagnosis.enumeratedProcesses.map(String.init) ?? "?"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { refresh() }
        .navigationDestination(isPresented: $showApps) { AppRecoveryView(initialPID: selectedAppPID) }
        .navigationDestination(isPresented: $showResources) { WorkResourceView() }
        .navigationDestination(isPresented: $showServers) { EnvironmentRetirementView(initialTab: "finish") }
    }

    private func refresh() {
        guard !busy else { return }
        busy = true
        Task {
            let result = await Task.detached(priority: .utility) { MemoryDiagnosis.capture() }.value
            previous = diagnosis; diagnosis = result; busy = false
        }
    }
    private func bytes(_ value: UInt64?) -> String { HealthSnapshot.bytes(value.map { Int64(clamping: $0) }) }
}
