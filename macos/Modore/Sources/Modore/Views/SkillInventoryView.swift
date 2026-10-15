import AppKit
import SwiftUI

struct SkillInventoryView: View {
    @EnvironmentObject private var model: ScanModel
    @StateObject private var service = SkillInventoryService()
    @State private var selection: String?
    @State private var compareID = ""
    @State private var query = ""
    @State private var host = "all"
    @State private var source: SkillSourceFilter = .all
    @State private var duplicatesOnly = false
    @State private var tab = "installations"
    @State private var approval: SkillInstallation?
    @State private var showDiff = false

    private var items: [SkillInstallation] { service.snapshot?.items ?? [] }
    private var visible: [SkillInstallation] {
        items.filter {
            (host == "all" || $0.host == host) && source.matches($0) &&
            (!duplicatesOnly || $0.duplicates > 1) &&
            (query.isEmpty || ($0.name + $0.origin + $0.path + $0.realPath).localizedCaseInsensitiveContains(query))
        }
    }
    private var focused: SkillInstallation? { visible.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let snapshot = service.snapshot {
                Text(L10n.message(snapshot.scope)).font(.callout).foregroundStyle(.secondary)
                if !snapshot.warnings.isEmpty {
                    DisclosureGroup(L10n.format("탐색 범위·확인 사항 %d건", snapshot.warnings.count)) {
                        ForEach(snapshot.warnings, id: \.self) { Text(L10n.message($0)).font(.caption).textSelection(.enabled) }
                    }
                }
            }
            if !service.error.isEmpty {
                Label(L10n.message(service.error), systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
            }
            Picker(L10n.text("보기"), selection: $tab) {
                Text(L10n.format("설치·참고 (%d)", items.count)).tag("installations")
                Text(L10n.format("백업·복구 (%d)", service.snapshot?.backups.count ?? 0)).tag("backups")
            }.pickerStyle(.segmented)
            if tab == "installations" { inventory } else { backups }
        }
        .padding(20)
        .disabled(service.busy)
        .overlay(alignment: .topTrailing) { if service.busy { ProgressView().controlSize(.small).padding(24) } }
        .onChange(of: selection) { _ in compareID = "" }
        .onAppear { service.startRead(["action": "status"], model: model) }
        .sheet(item: $approval) { item in
            VStack(alignment: .leading, spacing: 18) {
                Text(L10n.text("백업 후 이 설치 비활성화")).font(.title2.bold())
                Text(item.name).font(.headline)
                Text(item.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text(L10n.text("원본 폴더·해석된 파일 내용·링크·설정 사본을 보관한 뒤 이 경로를 옮깁니다. 다른 복사본, 링크 대상과 설정 파일은 변경하지 않습니다."))
                Text(L10n.message(service.snapshot?.scope ?? "")).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(L10n.text("취소")) { approval = nil }.keyboardShortcut(.cancelAction)
                    Button(L10n.text("백업하고 비활성화")) {
                        approval = nil
                        Task {
                            await service.perform(["action": "disable", "id": item.id, "fingerprint": item.fingerprint], model: model, mutation: true)
                            tab = "backups"
                        }
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 560)
        }
        .sheet(isPresented: $showDiff) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L10n.text("SKILL.md 내용 비교")).font(.title2.bold())
                    Spacer()
                    Button(L10n.text("닫기")) { showDiff = false }.keyboardShortcut(.cancelAction)
                }
                Text(L10n.text("− 원본 · + 비교 대상. 버전 문자열과 파일 내용의 동일 여부는 별개입니다.")).foregroundStyle(.secondary)
                ScrollView([.horizontal, .vertical]) {
                    Text(service.diff).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(24).frame(minWidth: 780, minHeight: 520)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(service.demo ? L10n.text("AI 스킬 · 격리된 검증 자료") : L10n.text("AI 스킬")).font(.title.bold())
                Text(L10n.text("홈의 Codex·Claude 설치와 플러그인 캐시 · 프로젝트별 스킬은 제외")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu(L10n.text("검증 자료")) {
                Button(service.demo ? L10n.text("내 설치로 돌아가기") : L10n.text("격리된 예제 열기")) {
                    service.startModeSwitch(model: model) {
                        selection = nil; compareID = ""; query = ""; host = "all"
                        source = .all; duplicatesOnly = false; tab = "installations"
                    }
                }
            }.fixedSize().accessibilityIdentifier("skills-demo-menu")
            Button(L10n.text("다시 읽기")) { service.startRead(["action": "status"], model: model) }.fixedSize()
        }
    }

    private var inventory: some View {
        VStack(spacing: 10) {
            HStack {
                TextField(L10n.text("이름·출처·표시/실제 경로 검색"), text: $query).textFieldStyle(.roundedBorder)
                Picker(L10n.text("호스트"), selection: $host) {
                    Text(L10n.text("전체")).tag("all")
                    Text("Codex").tag("Codex")
                    Text("Claude").tag("Claude")
                    Text(L10n.text("참고")).tag(SkillSourceFilter.referenceHost)
                }.frame(width: 150)
                Picker(L10n.text("출처"), selection: $source) {
                    ForEach(SkillSourceFilter.allCases) { Text($0.title).tag($0) }
                }.frame(width: 180)
                Toggle(L10n.text("중복만"), isOn: $duplicatesOnly).toggleStyle(.checkbox)
            }
            HSplitView {
                List(selection: $selection) {
                    ForEach(visible) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.name).font(.headline)
                            Text("\(L10n.message(item.host)) · \(L10n.message(item.source))").font(.caption).foregroundStyle(.secondary)
                            Text(item.origin).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            if item.duplicates > 1 {
                                Text(L10n.format("동명 %d개 · 내용 %d종", item.duplicates, item.variants)).font(.caption).foregroundStyle(item.variants > 1 ? .orange : .secondary)
                            }
                            if !item.error.isEmpty { Text(L10n.text("읽기 오류")).font(.caption).foregroundStyle(.red) }
                        }.padding(.vertical, 5).tag(item.id).accessibilityIdentifier("skills-item-" + item.id)
                    }
                }.frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                ScrollView {
                    if let item = focused { detail(item).padding(16) }
                    else {
                        VStack(spacing: 12) {
                            Image(systemName: "books.vertical").font(.largeTitle)
                            Text(visible.isEmpty ? L10n.text("조건에 맞는 설치가 없습니다") : L10n.text("설치를 선택해 경로와 상태를 확인하세요"))
                            Text(L10n.text("목록은 파일 인벤토리입니다. 모든 캐시가 활성 스킬이라는 뜻은 아닙니다.")).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(40)
                    }
                }.frame(minWidth: 340, maxWidth: .infinity)
            }
            HStack {
                Text(L10n.format("표시 %d개 / 파일 항목 %d개", visible.count, items.count)).font(.caption).foregroundStyle(.secondary)
                if let observed = service.snapshot?.observed {
                    Text(Date(timeIntervalSince1970: observed), style: .time).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("Codex 발견 확인")) { service.startRead(["action": "probe"], model: model) }.disabled(service.demo)
                    .help(L10n.text("별도 app-server에 홈 범위의 스킬 목록을 읽기 전용으로 요청합니다. 현재 대화의 로드 여부는 확인할 수 없습니다."))
            }
        }
    }

    private func detail(_ item: SkillInstallation) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(item.name).font(.title2.bold())
            Text(item.description).foregroundStyle(.secondary)
            evidenceSection(L10n.text("설치와 로드 근거")) {
                VStack(alignment: .leading, spacing: 8) {
                    field(L10n.text("호스트·출처"), "\(L10n.message(item.host)) · \(L10n.message(item.source)) · \(item.origin)")
                    field(L10n.text("파일"), item.exists ? L10n.text("SKILL.md 존재") : L10n.text("없음 / 끊어진 링크"))
                    field(L10n.text("발견·활성"), L10n.message(item.discovery))
                    field(L10n.text("현재 세션"), L10n.message(item.session))
                    field(L10n.text("버전"), L10n.message(item.version))
                    field(L10n.text("내용 SHA-256"), item.hash)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            evidenceSection(L10n.text("표시 경로와 실제 파일")) {
                VStack(alignment: .leading, spacing: 10) {
                    field(L10n.text("탐색 경로"), item.filePath)
                    field(L10n.text("실제 파일 경로"), item.realPath)
                    if !item.link.isEmpty { field(L10n.text("링크 원문"), item.link) }
                    Text(L10n.text("실제 경로는 링크를 해석한 파일 위치입니다. 세션이 이 파일을 읽었다는 증거는 아닙니다.")).font(.caption).foregroundStyle(.secondary)
                    Button(L10n.text("Finder에서 보기")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.filePath)]) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            comparison(item)
            if !item.error.isEmpty { Text(L10n.message(item.error)).foregroundStyle(.red).textSelection(.enabled) }
            Button(L10n.text("백업 후 비활성화…")) { approval = item }
                .disabled(!item.manageable || item.fingerprint.isEmpty || !item.error.isEmpty
                    || model.isBusy || (!service.demo && model.cleanupReviewOnly))
                .buttonStyle(.bordered)
                .accessibilityIdentifier("skills-disable")
        }
    }

    private func comparison(_ item: SkillInstallation) -> some View {
        let peers = items.filter { $0.id != item.id && $0.exists && $0.error.isEmpty && !$0.hash.isEmpty }
        let sameName = peers.filter { $0.name == item.name }
        let candidates = sameName.isEmpty ? peers : sameName
        let target = candidates.first { $0.id == compareID } ?? candidates.first
        return evidenceSection(L10n.text("중복·버전 비교")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.format("동명 파일 %d개 · SKILL.md 내용 %d종", item.duplicates, item.variants)).font(.callout)
                if let target, item.exists, item.error.isEmpty, !item.hash.isEmpty {
                    if candidates.count > 1 {
                        Picker(L10n.text("비교 대상"), selection: Binding(get: { target.id }, set: { compareID = $0 })) {
                            ForEach(candidates) { peer in
                                Text("\(L10n.message(peer.host)) · \(peer.origin) · \(L10n.message(peer.version)) · \(peer.name)").tag(peer.id)
                            }
                        }
                    } else {
                        Text("\(L10n.message(target.host)) · \(target.origin) · \(L10n.message(target.version))").font(.callout)
                    }
                    field(L10n.text("대상 경로"), target.filePath)
                    Text(item.hash == target.hash ? L10n.text("SKILL.md 내용 동일") : L10n.text("SKILL.md 내용 다름")).foregroundStyle(item.hash == target.hash ? Color.secondary : Color.orange)
                    Button(L10n.text("차이 보기")) {
                        service.startRead(["action": "compare", "ids": [item.id, target.id]], model: model) {
                            showDiff = true
                        }
                    }
                } else { Text(L10n.text("비교할 다른 설치가 없습니다.")).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }

    private var backups: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if service.snapshot?.backups.isEmpty != false { Text(L10n.text("아직 백업이 없습니다. 설치를 선택하고 ‘백업 후 비활성화’를 실행하세요.")).padding(24) }
                ForEach(service.snapshot?.backups ?? []) { backup in
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(backup.name).font(.headline)
                                Text(backup.stateTitle).foregroundStyle(backup.state == "restored" ? .green : .secondary)
                                Spacer()
                                Text(Date(timeIntervalSince1970: backup.created), style: .date).font(.caption)
                            }
                            field(L10n.text("원래 경로"), backup.original)
                            field(L10n.text("보관 위치"), backup.backupPath)
                            if !backup.error.isEmpty { Label(L10n.message(backup.error), systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
                            HStack {
                                Button(L10n.text("백업 폴더 열기")) { NSWorkspace.shared.open(URL(fileURLWithPath: backup.backupPath)) }
                                Button(L10n.text("원래 위치로 복구")) {
                                    Task { await service.perform(["action": "restore", "id": backup.id], model: model, mutation: true) }
                                }.disabled(!["disabled", "needsAttention", "backedUp"].contains(backup.state)
                                    || model.isBusy || (!service.demo && model.cleanupReviewOnly))
                            }
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                }
            }
        }
    }

    private func evidenceSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
            Divider()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? L10n.text("미확인") : value).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
