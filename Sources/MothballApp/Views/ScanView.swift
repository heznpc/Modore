import SwiftUI
import MothballCore

struct ScanView: View {
    @EnvironmentObject var model: AppModel
    @State private var sortOrder: [KeyPathComparator<InspectedRepo>] = [
        .init(\.info.sizeBytes, order: .reverse)
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("스캔 위치").font(.headline)

            ForEach(model.scanLocations, id: \.self) { url in
                LocationChip(url: url) {
                    model.removeScanLocation(url)
                }
            }

            Button {
                pickScanLocation()
            } label: {
                Label("위치 추가", systemImage: "plus")
            }

            Spacer()

            Button {
                model.runScan()
            } label: {
                if model.scanState == .running {
                    ProgressView().controlSize(.small)
                } else {
                    Label("스캔", systemImage: "magnifyingglass")
                }
            }
            .disabled(model.scanLocations.isEmpty || model.scanState == .running)
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(12)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.scanState {
        case .idle:
            placeholder("스캔할 폴더를 추가하고 스캔 버튼을 누르세요")
        case .running where model.inspectedRepos.isEmpty:
            placeholder("스캔 중...")
        case .done where model.inspectedRepos.isEmpty:
            placeholder("발견된 git 저장소가 없습니다")
        default:
            repoTable
        }
    }

    private func placeholder(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var repoTable: some View {
        Table(of: InspectedRepo.self, sortOrder: $sortOrder) {
            TableColumn("") { repo in
                Toggle("", isOn: Binding(
                    get: { repo.isSelected },
                    set: { _ in model.toggleSelection(of: repo.id) }
                ))
                .labelsHidden()
                .disabled(repo.verdict.tier == .unsafe)
            }
            .width(28)

            TableColumn("이름") { repo in
                Text(repo.info.path.lastPathComponent)
                    .lineLimit(1)
                    .help(repo.info.path.path)
            }

            TableColumn("크기", value: \.info.sizeBytes) { repo in
                Text(repo.info.sizeBytes.fileSizeString)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80)

            TableColumn("마지막 활동") { repo in
                Text(relativeDateString(repo.info.lastActivity))
                    .help(repo.info.lastActivity.formatted())
            }
            .width(min: 100)

            TableColumn("상태") { repo in
                TierBadge(verdict: repo.verdict)
            }
            .width(min: 120)
        } rows: {
            ForEach(sortedRepos) { repo in
                TableRow(repo)
            }
        }
    }

    private var sortedRepos: [InspectedRepo] {
        model.inspectedRepos.sorted(using: sortOrder)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("선택 \(model.selectedRepos.count)개  •  ")
                + Text(model.selectedTotalBytes.fileSizeString).bold()
                + Text(" 회수 가능")

            Spacer()

            Button("아카이브...") {
                model.requestArchiveConfirmation()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .liquidProminentActionStyle()
            .disabled(model.selectedRepos.isEmpty)
        }
        .padding(12)
    }

    // MARK: - Actions

    private func pickScanLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "스캔할 폴더를 선택하세요"
        if panel.runModal() == .OK, let url = panel.url {
            model.addScanLocation(url)
        }
    }
}

// MARK: -

struct LocationChip: View {
    let url: URL
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder")
            Text(url.lastPathComponent).help(url.path)
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .liquidGlassChip()
    }
}

struct TierBadge: View {
    let verdict: SafetyVerdict

    var body: some View {
        let (label, color) = display
        Text(label)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .liquidTintedChip(color)
            .foregroundStyle(color)
            .help(verdict.reasons.map(\.humanDescription).joined(separator: "\n"))
    }

    private var display: (String, Color) {
        switch verdict.tier {
        case .safe:    return ("안전", .green)
        case .caution: return ("주의", .orange)
        case .unsafe:  return ("보관 금지", .red)
        }
    }
}

