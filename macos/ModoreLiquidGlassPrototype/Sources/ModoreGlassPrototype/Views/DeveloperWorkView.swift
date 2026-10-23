import SwiftUI

struct DeveloperWorkView: View {
    @Bindable var state: PrototypeState
    @State private var showBackup = false
    private var project: ProjectSample { ProjectSample.samples.first { $0.id == state.projectID } ?? ProjectSample.samples[0] }
    private var conversations: [ConversationSample] {
        project.conversations.filter { state.workQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(state.workQuery) }
    }
    private var conversation: ConversationSample? { project.conversations.first { $0.id == state.conversationID } }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("프로젝트").font(.caption).foregroundStyle(.secondary)
                    Picker("프로젝트", selection: $state.projectID) {
                        ForEach(ProjectSample.samples) { Text($0.name).tag($0.id) }
                    }.labelsHidden().controlSize(.large)
                    HStack {
                        Text("대화 \(project.conversations.count)개").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("개요") { state.conversationID = nil }.buttonStyle(.plain).font(.caption).foregroundStyle(.blue)
                    }
                }.padding(18)
                Divider()
                if conversations.isEmpty {
                    ContentUnavailableView("검색 결과 없음", systemImage: "magnifyingglass", description: Text("“\(state.workQuery)”에 맞는 대화 제목이 없습니다."))
                        .frame(maxHeight: .infinity)
                } else {
                    List(conversations, selection: $state.conversationID) { conversation in
                        VStack(alignment: .leading, spacing: 9) {
                            Text(conversation.title).fontWeight(.medium).lineLimit(2)
                            HStack {
                                Text(conversation.source)
                                Spacer()
                                Text(conversation.time)
                            }.font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 10).tag(conversation.id)
                    }.listStyle(.inset)
                }
                Text("제목 검색 · 예시 대화").font(.caption2).foregroundStyle(.tertiary).padding(18)
            }
            .frame(minWidth: 240, idealWidth: 270, maxWidth: 330)

            Group {
                if let conversation {
                    ConversationReader(project: project, conversation: conversation)
                } else {
                    projectOverview
                }
            }.frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $state.workQuery, prompt: "대화 제목 검색")
        .onChange(of: state.projectID) { _, _ in
            state.conversationID = nil
            state.workQuery = ""
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showBackup = true } label: { Label("백업 검토", systemImage: "archivebox") }
                    .help("선택한 프로젝트의 백업 검토")
            }
        }
        .sheet(isPresented: $showBackup) { BackupPreviewSheet(project: project) }
    }

    private var projectOverview: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "folder").font(.system(size: 42, weight: .light)).foregroundStyle(.secondary)
            Text(project.name).font(.largeTitle.weight(.semibold))
            Text(project.subtitle).foregroundStyle(.secondary)
            Divider()
            LabeledContent("연결된 대화", value: "\(project.conversations.count)개")
            LabeledContent("원본", value: "보존됨 · 예시")
            Text("목록에서 대화를 선택하면 작업 맥락을 이어서 읽을 수 있습니다.")
                .foregroundStyle(.secondary).lineSpacing(4)
            Button("최근 대화 읽기") { state.conversationID = project.conversations.first?.id }
                .buttonStyle(.glass).controlSize(.large)
            Spacer()
        }.padding(36).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConversationReader: View {
    let project: ProjectSample
    let conversation: ConversationSample
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 27) {
                HStack(spacing: 7) {
                    Image(systemName: "folder")
                    Text(project.name)
                    Image(systemName: "chevron.right").font(.caption2)
                    Text(conversation.source)
                }.font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 12) {
                    Text(conversation.title).font(.system(size: 27, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(conversation.summary).font(.title3).foregroundStyle(.secondary).lineSpacing(5)
                    Text(conversation.time + " · 예시 대화").font(.caption).foregroundStyle(.tertiary)
                }
                Divider()
                ForEach(Array(conversation.paragraphs.enumerated()), id: \.offset) { index, paragraph in
                    VStack(alignment: .leading, spacing: 10) {
                        Label(index == 0 ? "요청" : "설계 메모", systemImage: index == 0 ? "person.crop.circle" : "sparkle")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(paragraph).font(.system(size: 14)).lineSpacing(7).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Divider()
                Label("프로젝트 원본과 연결된 대화 흐름의 예시입니다", systemImage: "link")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(32).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
        .id(conversation.id)
    }
}

struct BackupPreviewSheet: View {
    let project: ProjectSample
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("백업 검토", systemImage: "archivebox").font(.title2.weight(.semibold))
            Text(project.name).font(.headline)
            LabeledContent("포함할 대화", value: "\(project.conversations.count)개")
            LabeledContent("원본 처리", value: "원본 유지")
            Text("프로토타입에서는 백업 범위의 미리보기만 제공합니다. 파일 생성이나 대화 원본의 이동은 수행하지 않습니다.")
                .foregroundStyle(.secondary).lineSpacing(5)
            HStack { Spacer(); Button("완료") { dismiss() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 440)
    }
}
