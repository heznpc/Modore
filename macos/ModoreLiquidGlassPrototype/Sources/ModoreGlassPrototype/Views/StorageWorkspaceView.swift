import SwiftUI

struct StorageWorkspaceView: View {
    @Bindable var state: PrototypeState
    @State private var candidatesOnly = false
    @State private var showReview = false
    @State private var sortOrder: [KeyPathComparator<StorageItem>] = []
    @Namespace private var glassNamespace
    private var items: [StorageItem] { StorageItem.samples.filter { !candidatesOnly || $0.eligible }.sorted(using: sortOrder) }
    private var selected: StorageItem? { StorageItem.samples.first { $0.id == state.storageSelection } }
    private var checked: [StorageItem] { StorageItem.samples.filter { state.cleanupSelection.contains($0.id) && $0.eligible } }
    private var total: String { String(format: "%.1f GiB", checked.reduce(0) { $0 + $1.gib }) }

    var body: some View {
        VStack(spacing: 0) {
            storageSummary.padding(24)
            HStack {
                Picker("표시 항목", selection: $candidatesOnly) {
                    Text("전체 항목").tag(false)
                    Text("정리 후보").tag(true)
                }.pickerStyle(.segmented).frame(width: 230)
                Spacer()
                Text("\(items.count)개 항목").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 24).padding(.bottom, 16)
            Table(items, selection: $state.storageSelection, sortOrder: $sortOrder) {
                TableColumn("선택") { item in
                    Toggle("\(item.name) 정리 선택", isOn: Binding(
                        get: { state.cleanupSelection.contains(item.id) },
                        set: { value in
                            if value { state.cleanupSelection.insert(item.id) } else { state.cleanupSelection.remove(item.id) }
                        }
                    ))
                    .toggleStyle(.checkbox).labelsHidden().disabled(!item.eligible)
                    .help(item.eligible ? "검토 대상으로 선택" : item.status + " · 정리 대상 제외")
                }.width(34)
                TableColumn("항목", value: \.name) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol).font(.title3).foregroundStyle(.secondary).frame(width: 22)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).fontWeight(.medium)
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 10)
                    }
                }.width(min: 160, ideal: 240)
                TableColumn("크기", value: \.gib) { Text($0.size).monospacedDigit() }.width(78)
                TableColumn("상태") { item in
                    Text(item.status).font(.callout).foregroundStyle(item.status == "사용 중" ? Color.orange : .secondary)
                }.width(90)
            }
            .alternatingRowBackgrounds(.disabled)
            .safeAreaInset(edge: .bottom, spacing: 0) { selectionBar.padding(18) }
        }
        .inspector(isPresented: $state.showStorageInspector) {
            StorageInspector(item: selected)
                .inspectorColumnWidth(min: 240, ideal: 260, max: 300)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { state.showStorageInspector.toggle() } label: { Label("항목 정보", systemImage: "sidebar.right") }
                    .help("선택한 항목 정보 보기")
            }
        }
        .sheet(isPresented: $showReview) { CleanupReviewSheet(items: checked) }
    }

    private var storageSummary: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Macintosh HD").font(.headline)
                    Text("전체 1 TiB · 예시 데이터").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("83.2").font(.system(size: 30, weight: .semibold)).monospacedDigit()
                Text("GiB 여유").foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    Color.blue.opacity(0.8).frame(width: geometry.size.width * 0.43)
                    Color.blue.opacity(0.45).frame(width: geometry.size.width * 0.27)
                    Color.secondary.opacity(0.42).frame(width: geometry.size.width * 0.21)
                    Color.secondary.opacity(0.12)
                }.clipShape(Capsule())
            }.frame(height: 10).accessibilityLabel("디스크 공간 약 92퍼센트 사용")
            HStack(spacing: 16) {
                legend("파일", color: .blue.opacity(0.8))
                legend("앱", color: .blue.opacity(0.45))
                legend("시스템", color: .secondary.opacity(0.42))
                Spacer()
                Text("정리 후보 10.5 GiB").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func legend(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) { Circle().fill(color).frame(width: 6, height: 6); Text(text).font(.caption).foregroundStyle(.secondary) }
    }

    private var selectionBar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: checked.isEmpty ? "checklist" : "checkmark.circle.fill").foregroundStyle(checked.isEmpty ? Color.secondary : .blue)
                    Text(checked.isEmpty ? "체크한 항목만 검토합니다" : "\(checked.count)개 선택 · \(total)").font(.callout.weight(.medium)).monospacedDigit()
                    if !checked.isEmpty {
                        Button { withAnimation { state.cleanupSelection.removeAll() } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).help("정리 선택 해제").accessibilityLabel("정리 선택 해제")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .glassEffect(.regular, in: Capsule()).glassEffectID("selection", in: glassNamespace)
                Button("검토…") { showReview = true }
                    .buttonStyle(.glassProminent).controlSize(.large).disabled(checked.isEmpty)
                    .accessibilityLabel("선택한 \(checked.count)개 검토")
            }
        }
    }
}

struct StorageInspector: View {
    let item: StorageItem?
    var body: some View {
        if let item {
            ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: item.symbol).font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
                        Text(item.name).font(.title3.weight(.semibold))
                        Text(item.size).font(.title2).monospacedDigit()
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Label(item.status, systemImage: item.eligible ? "arrow.trianglehead.2.clockwise.rotate.90" : "lock.shield")
                            .font(.headline)
                        Text(item.explanation).foregroundStyle(.secondary).lineSpacing(4)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("위치").font(.headline)
                        Text(item.path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("관찰 정보").font(.headline)
                        Text("예시 데이터 · 전체 하위 항목\n실제 사용 여부는 검사하지 않았습니다.").font(.caption).foregroundStyle(.secondary).lineSpacing(5)
                    }
                    Label("항목 열람은 정리 선택과 별개입니다", systemImage: "cursorarrow")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(22)
            }
        } else {
            ContentUnavailableView("항목 선택", systemImage: "sidebar.right", description: Text("목록에서 항목을 선택하면 근거와 위치를 볼 수 있습니다."))
        }
    }
}

struct CleanupReviewSheet: View {
    let items: [StorageItem]
    @Environment(\.dismiss) private var dismiss
    @State private var completed = false
    private var total: String { String(format: "%.1f GiB", items.reduce(0) { $0 + $1.gib }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 13) {
                Image(systemName: completed ? "checkmark.circle" : "checklist").font(.system(size: 30, weight: .light)).foregroundStyle(completed ? Color.green : .primary)
                VStack(alignment: .leading, spacing: 5) {
                    Text(completed ? "검토 흐름을 확인했습니다" : "선택한 \(items.count)개 검토").font(.title2.weight(.semibold))
                    Text(completed ? "실제 파일은 변경되지 않았습니다." : "예상 파일 크기 \(total) · 실제 확보량은 다를 수 있음")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(item.name).fontWeight(.semibold); Spacer(); Text(item.size).monospacedDigit() }
                    Text(item.path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Text(item.explanation).font(.callout).foregroundStyle(.secondary)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
            }
            Text("프로토타입에서는 선택과 검토 흐름만 체험합니다. 실제 정리·백업·되돌리기는 연결되어 있지 않습니다.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                if !completed { Button("취소") { dismiss() }.keyboardShortcut(.cancelAction) }
                Button(completed ? "완료" : "검토 완료 체험") {
                    if completed { dismiss() } else { completed = true }
                }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 580)
    }
}
