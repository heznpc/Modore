import SwiftUI

struct CleanupHistoryView: View {
    @ObservedObject var history: CleanupHistory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = history.errorMessage {
                Text(error).foregroundStyle(.red)
            }
            if let receipt = history.receipts.first {
                Label("Latest cleanup", systemImage: "clock.arrow.circlepath").font(.headline)
                Text(status(receipt)).font(.subheadline)
                Text("Deleted: \(receipt.deletedCount) / \(receipt.requestedCount)")
                LabeledContent("Available before", value: bytes(receipt.beforeBytes))
                LabeledContent("Available after", value: bytes(receipt.afterBytes))
                if let change = receipt.availableChange {
                    LabeledContent("Available-space change", value: (change < 0 ? "−" : "+") + StorageFormatting.bytes(abs(change)))
                }
                Text("Capacity is measured for the whole device. Other activity and Recently Deleted can affect the result.")
                    .font(.caption).foregroundStyle(.secondary)
                Text((receipt.finishedAt ?? receipt.startedAt).formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func bytes(_ value: Int64?) -> String {
        value.map { StorageFormatting.bytes($0) } ?? String(localized: "Not measured")
    }

    private func status(_ receipt: CleanupReceipt) -> String {
        switch receipt.status {
        case .inProgress: history.activeReceipts.contains(receipt.id) ? String(localized: "Deleting…")
            : String(localized: "No final result was recorded. Check the selected items before trying again.")
        case .completed: receipt.kind == .media ? String(localized: "Moved to Recently Deleted") : String(localized: "File deletion finished")
        case .partial: String(localized: "Only some selected items were deleted.")
        case .failed: String(localized: "Deletion did not finish. Review the items before trying again.")
        case .cancelled: String(localized: "Deletion cancelled.")
        }
    }
}

struct CleanupConfirmationView<Preview: View>: View {
    let count: Int
    let warning: LocalizedStringKey
    let preview: Preview
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    init(count: Int, warning: LocalizedStringKey, @ViewBuilder preview: () -> Preview, confirm: @escaping () -> Void) {
        self.count = count
        self.warning = warning
        self.preview = preview()
        self.confirm = confirm
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Selected items: \(count)").font(.headline)
                    Text(warning)
                }
                Section("Review every selected item") { preview }
                Section {
                    Button("Delete selected items", role: .destructive) {
                        dismiss()
                        confirm()
                    }
                    .accessibilityIdentifier("confirm-cleanup")
                }
            }
            .navigationTitle("Confirm deletion")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
