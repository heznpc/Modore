import SwiftUI

struct MacStatusView: View {
    @Bindable var state: PrototypeState
    @State private var detail: HealthDetail?

    private var isUnmeasured: Bool { state.scenario == .unavailable }
    private var needsAttention: Bool { state.scenario == .attention }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    Label("이 Mac", systemImage: "laptopcomputer").font(.headline)
                    Spacer()
                    Text("예시 관찰 · \(state.observedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.callout).foregroundStyle(.secondary)
                }
                overview
                VStack(alignment: .leading, spacing: 12) {
                    Text("현재 상태").font(.headline)
                    VStack(spacing: 0) {
                        metric("저장공간", symbol: "internaldrive", value: "83.2 GiB 여유", note: "전체 1 TiB · 정리 후보 10.5 GiB", progress: 0.92, color: .blue) { state.area = .storage }
                        Divider().padding(.leading, 49)
                        metric("메모리", symbol: "memorychip", value: needsAttention ? "압력 높음" : "압력 정상", note: needsAttention ? "27.4 / 32 GiB 사용 · 스왑 2.1 GiB" : "18.6 / 32 GiB 사용 · 스왑 0.2 GiB", progress: needsAttention ? 0.85 : 0.58, color: needsAttention ? .orange : .green) { detail = .memory }
                        Divider().padding(.leading, 49)
                        metric("CPU", symbol: "cpu", value: "18% 사용", note: "현재 관찰 · 최근 최고 54%", progress: 0.18, color: .green) { detail = .cpu }
                        Divider().padding(.leading, 49)
                        metric("전원", symbol: "battery.100percent", value: "전원 연결됨", note: "배터리 100% · 충전 완료", progress: nil, color: .green) { detail = .power }
                        Divider().padding(.leading, 49)
                        metric("네트워크", symbol: "wifi", value: "Wi-Fi 연결됨", note: "현재 연결 상태 · 속도 미측정", progress: nil, color: .green) { detail = .network }
                    }
                    .background(.background, in: .rect(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.45), lineWidth: 0.5))
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("도구").font(.headline)
                    HStack(spacing: 12) {
                        tool("앱 사용량 보기", note: "메모리와 CPU 사용 비교", symbol: "app.badge") { detail = .memory }
                        tool("권한 확인", note: "관찰 가능한 범위 확인", symbol: "lock.shield") { detail = .permissions }
                    }
                }
                Text("수치와 상태는 화면 검토를 위한 예시입니다. 실제 Mac 진단은 실행하지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(28).frame(maxWidth: 900).frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Mac 상태 예시", selection: $state.scenario) {
                        ForEach(HealthScenario.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: { Label("상태 예시", systemImage: "slider.horizontal.3") }
                .help("정상·주의·미측정 상태 비교")
            }
        }
        .sheet(item: $detail) { HealthDetailSheet(detail: $0, unmeasured: isUnmeasured) }
    }

    private var overview: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: isUnmeasured ? "questionmark.circle" : needsAttention ? "exclamationmark.circle" : "checkmark.circle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(isUnmeasured ? Color.secondary : needsAttention ? .orange : .green)
            VStack(alignment: .leading, spacing: 7) {
                Text(isUnmeasured ? "아직 관찰한 정보가 없습니다" : needsAttention ? "메모리 사용량을 확인해 보세요" : "관찰한 항목은 안정적입니다")
                    .font(.title2.weight(.semibold))
                Text(isUnmeasured ? "예시 상태를 바꾸어 관찰 결과를 살펴보세요." : needsAttention ? "메모리 압력이 높습니다. 사용량이 큰 앱부터 확인할 수 있습니다." : "현재 관찰 범위에서 주의 신호가 없습니다.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if needsAttention {
                Button("앱 확인") { detail = .memory }
                    .buttonStyle(.glass).controlSize(.large)
            }
        }
        .padding(.vertical, 10)
        .frame(minHeight: 84)
    }

    private func metric(_ title: String, symbol: String, value: String, note: String, progress: Double?, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(.secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).fontWeight(.medium)
                    Text(isUnmeasured ? "아직 관찰하지 않음" : note).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                if let progress, !isUnmeasured {
                    ProgressView(value: progress).tint(color).frame(width: 76).accessibilityHidden(true)
                }
                Text(isUnmeasured ? "미측정" : value).monospacedDigit().foregroundStyle(isUnmeasured ? Color.secondary : .primary).frame(minWidth: 106, alignment: .trailing)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 17).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(isUnmeasured ? "미측정" : value), 상세 보기")
    }

    private func tool(_ title: String, note: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).fontWeight(.medium)
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(16).frame(maxWidth: .infinity).background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
}

enum HealthDetail: String, Identifiable {
    case memory = "앱 사용량", cpu = "CPU", power = "전원", network = "네트워크", permissions = "권한"
    var id: Self { self }
}

struct HealthDetailSheet: View {
    let detail: HealthDetail
    let unmeasured: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(detail.rawValue).font(.title2.bold())
            Text("예시 관찰 결과").font(.callout).foregroundStyle(.secondary)
            if unmeasured {
                ContentUnavailableView("미측정", systemImage: "questionmark.circle", description: Text("관찰하지 않은 수치를 0으로 표시하지 않습니다."))
            } else if detail == .memory || detail == .cpu {
                ForEach(Array([("Xcode", "8.2 GiB", "12%"), ("Simulator", "4.6 GiB", "3%"), ("Safari", "3.1 GiB", "2%")].enumerated()), id: \.offset) { _, app in
                    HStack { Image(systemName: "app").foregroundStyle(.secondary); Text(app.0); Spacer(); Text(app.1).monospacedDigit(); Text(app.2).monospacedDigit().foregroundStyle(.secondary).frame(width: 55, alignment: .trailing) }
                    Divider()
                }
                Text("앱의 작업 상태를 확인한 뒤 사용하지 않는 창을 닫아 보세요. 이 프로토타입에서는 앱을 종료하지 않습니다.").foregroundStyle(.secondary)
            } else {
                LabeledContent(detail == .power ? "전원 상태" : detail == .network ? "연결 상태" : "기본 시스템 정보", value: detail == .power ? "충전 완료" : detail == .network ? "Wi-Fi 연결됨" : "관찰 가능")
                LabeledContent(detail == .permissions ? "보호된 폴더" : "관찰 범위", value: detail == .permissions ? "추가 권한 필요" : "현재 상태만")
                Text("예시 정보입니다. 시스템 설정이나 권한을 변경하지 않습니다.").foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("완료") { dismiss() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 490)
    }
}
