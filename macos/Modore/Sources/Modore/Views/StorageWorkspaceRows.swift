import SwiftUI

struct WorkspaceStorageItemRow: View {
    @EnvironmentObject private var model: ScanModel
    let item: StorageItem
    let fallbackSymbol: String
    var detail: String?
    let status: String?
    let actionTitle: String?
    let action: () -> Void

    init(
        item: StorageItem,
        fallbackSymbol: String,
        detail: String? = nil,
        status: String? = nil,
        actionTitle: String? = nil,
        action: @escaping () -> Void = {}
    ) {
        self.item = item
        self.fallbackSymbol = fallbackSymbol
        self.detail = detail
        self.status = status
        self.actionTitle = actionTitle
        self.action = action
    }

    @ViewBuilder
    var body: some View {
        if let actionTitle {
            Button(action: action) {
                rowContent
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)
            .accessibilityLabel(accessibilityText(actionTitle: actionTitle))
            .accessibilityHint("실행 전에 현재 경로와 크기를 다시 확인합니다.")
        } else {
            rowContent
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityText(actionTitle: nil))
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            WorkspaceItemIdentity(
                item: item,
                fallbackSymbol: fallbackSymbol,
                detail: detailText
            )
            Text(item.sizeText)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 72, alignment: .trailing)
            WorkspaceItemAccessory(
                status: status,
                actionTitle: actionTitle
            )
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .help([detailText, item.path].filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    private var detailText: String {
        detail ?? (item.note.isEmpty ? item.action : item.note)
    }

    private func accessibilityText(actionTitle: String?) -> String {
        [actionTitle, item.label, item.sizeText, status, detailText, item.path]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

private struct WorkspaceItemIdentity: View {
    let item: StorageItem
    let fallbackSymbol: String
    let detail: String

    var body: some View {
        NativeSourceIcon(item: item, fallbackSymbol: fallbackSymbol)
        VStack(alignment: .leading, spacing: 3) {
            Text(item.label)
                .font(.body.weight(.medium))
                .lineLimit(1)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(detail)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
    }
}

private struct WorkspaceItemAccessory: View {
    let status: String?
    let actionTitle: String?

    var body: some View {
        Group {
            if let actionTitle {
                Text(actionTitle)
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            } else if let status {
                Text(status)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 116, alignment: .trailing)
    }
}
