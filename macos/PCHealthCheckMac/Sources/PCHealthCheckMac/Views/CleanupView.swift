import AppKit
import SwiftUI

enum ModernStorageRowMode: String {
    case cleanup
    case protected
    case developer
}

struct CleanupPage: View {
    @EnvironmentObject private var model: ScanModel
    @State private var selectedKey: String?

    var body: some View {
        Group {
            if let storage = model.storage {
                InspectorSplitLayout {
                    CleanupSelectionList(storage: storage, selection: $selectedKey)
                } detail: {
                    Group {
                        if let record = selectedRecord(in: storage) {
                            CleanupInspectorPane(item: record.item, mode: record.mode)
                        } else {
                            ModernEmptyState(
                                symbol: "sidebar.right",
                                title: "항목을 선택하세요",
                                message: "왼쪽 목록에서 확인할 항목을 선택하세요."
                            )
                        }
                    }
                }
                .onAppear {
                    repairSelection(in: storage)
                }
                .onChange(of: selectionFingerprint(for: storage)) { _ in
                    repairSelection(in: storage)
                }
            } else {
                ModernEmptyState(symbol: "trash", title: "검사 결과가 없습니다", message: "지금 검사를 실행해 정리 후보를 찾으세요.")
            }
        }
    }

    private func selectedRecord(in storage: StorageSnapshot) -> (item: StorageItem, mode: ModernStorageRowMode)? {
        guard let selectedKey else { return nil }
        if let item = storage.cleanupCandidates.first(where: {
            selectionKey(for: $0, mode: .cleanup) == selectedKey
        }) {
            return (item, .cleanup)
        }
        if let item = storage.reviewCandidates.first(where: {
            selectionKey(for: $0, mode: .protected) == selectedKey
        }) {
            return (item, .protected)
        }
        return nil
    }

    private func repairSelection(in storage: StorageSnapshot) {
        let candidates = storage.cleanupCandidates.map {
            selectionKey(for: $0, mode: .cleanup)
        } + storage.reviewCandidates.map {
            selectionKey(for: $0, mode: .protected)
        }
        selectedKey = WorkspaceSelectionKey.repairedSelection(
            current: selectedKey,
            candidates: candidates
        )
    }

    private func selectionFingerprint(for storage: StorageSnapshot) -> String {
        let cleanup = storage.cleanupCandidates.map {
            selectionKey(for: $0, mode: .cleanup) + ":" + $0.measureStatus
        }
        let protected = storage.reviewCandidates.map {
            selectionKey(for: $0, mode: .protected) + ":" + $0.measureStatus
        }
        return (cleanup + protected).joined(separator: "|")
    }
}

struct CleanupSelectionList: View {
    @EnvironmentObject private var model: ScanModel
    let storage: StorageSnapshot
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(storage.cleanupCandidates) { item in
                    CleanupSelectionRow(item: item, mode: .cleanup)
                        .tag(selectionKey(for: item, mode: .cleanup))
                        .contextMenu {
                            Button { model.revealStorageItem(item) } label: {
                                Label("Finder에서 보기", systemImage: "folder")
                            }
                            Button { model.copyGuide(for: item) } label: {
                                Label("가이드 복사", systemImage: "doc.on.clipboard")
                            }
                        }
                }
            } header: {
                InspectorListHeader(
                    title: "정리 후보",
                    subtitle: "미리보기와 개별 승인을 거칩니다.",
                    value: "논리 \(storage.reclaimableText)"
                )
            }

            Section {
                ForEach(storage.reviewCandidates) { item in
                    CleanupSelectionRow(item: item, mode: .protected)
                        .tag(selectionKey(for: item, mode: .protected))
                        .contextMenu {
                            Button { model.revealStorageItem(item) } label: {
                                Label("Finder에서 보기", systemImage: "folder")
                            }
                            Button { model.copyGuide(for: item) } label: {
                                Label("가이드 복사", systemImage: "doc.on.clipboard")
                            }
                        }
                }
            } header: {
                InspectorListHeader(
                    title: "보호 및 확인",
                    subtitle: "기록과 내부 DB는 자동 정리하지 않습니다.",
                    value: storage.reviewText
                )
            }
        }
        .listStyle(.inset)
        .accessibilityLabel("공간 정리 항목")
    }
}

struct CleanupSelectionRow: View {
    let item: StorageItem
    let mode: ModernStorageRowMode

    var body: some View {
        HStack(spacing: 10) {
            NativeSourceIcon(item: item, fallbackSymbol: rowSymbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(item.note.isEmpty ? item.action : item.note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Spacer(minLength: 12)
            Text(item.sizeText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.label), \(item.sizeText)")
    }

    private var rowSymbol: String {
        if item.measureStatus == "timed_out" { return "hourglass" }
        if mode == .protected { return "lock.shield" }
        if item.label.localizedCaseInsensitiveContains("Playwright") {
            return "rectangle.stack.badge.play"
        }
        if item.label.localizedCaseInsensitiveContains("cache") {
            return "folder.badge.gearshape"
        }
        return "arrow.triangle.2.circlepath"
    }
}
