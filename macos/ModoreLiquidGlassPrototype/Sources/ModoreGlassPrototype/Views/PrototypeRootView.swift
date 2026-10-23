import SwiftUI

struct PrototypeRootView: View {
    @Bindable var state: PrototypeState
    @State private var showAbout = false

    var body: some View {
        NavigationSplitView {
            List(WorkspaceArea.allCases, selection: $state.area) { area in
                Label(area.title, systemImage: area.symbol)
                    .padding(.vertical, 5)
                    .tag(area)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 185, ideal: 205, max: 250)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("MODORE").font(.caption.weight(.semibold)).tracking(1.8)
                    Text("Liquid Glass Prototype").font(.caption).foregroundStyle(.secondary)
                    Text("예시 데이터").font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        } detail: {
            Group {
                switch state.area ?? .health {
                case .health: MacStatusView(state: state)
                case .storage: StorageWorkspaceView(state: state)
                case .work: DeveloperWorkView(state: state)
                }
            }
            .navigationTitle((state.area ?? .health).title)
            .navigationSubtitle("Modore · Prototype")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await state.refresh() }
                    } label: {
                        Label("예시 새로고침", systemImage: "arrow.clockwise")
                            .symbolEffect(.rotate, options: .repeating, isActive: state.refreshing)
                    }
                    .help("예시 관찰 시각 새로고침 (⌘R)")
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(state.refreshing)
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    Button { showAbout = true } label: {
                        Label("프로토타입 정보", systemImage: "info.circle")
                    }.help("외관 및 빌드 정보")
                }
            }
        }
        .sheet(isPresented: $showAbout) { PrototypeInfoSheet(state: state) }
    }
}

struct PrototypeInfoSheet: View {
    @Bindable var state: PrototypeState
    @Environment(\.dismiss) private var dismiss
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "PrototypeBuiltAt") as? String ?? "개발 빌드" }
    private var source: String { Bundle.main.object(forInfoDictionaryKey: "PrototypeSourceDigest") as? String ?? "—" }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                Image(systemName: "macwindow").font(.largeTitle).padding(14).glassEffect(in: .rect(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Modore Glass Prototype").font(.title2.bold())
                    Text("SwiftUI · macOS Liquid Glass").foregroundStyle(.secondary)
                }
            }
            Text("Mac 상태, 저장공간, 개발 작업의 탐색과 검토 흐름을 체험하는 앱입니다. 수치와 대화는 예시이며 실제 파일을 변경하지 않습니다.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("외관", selection: $state.appearance) {
                ForEach(PrototypeAppearance.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            LabeledContent("이번 빌드", value: build).font(.callout)
            LabeledContent("소스 식별값", value: source).font(.system(.caption, design: .monospaced))
            LabeledContent("최소 지원", value: "macOS 26").font(.callout)
            Divider()
            HStack {
                Link("Apple 디자인 리소스", destination: URL(string: "https://developer.apple.com/design/resources/#macos-apps")!)
                Spacer()
                Button("완료") { dismiss() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28).frame(width: 480)
        .preferredColorScheme(state.appearance.scheme)
    }
}
