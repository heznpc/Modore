import SwiftUI
import UniformTypeIdentifiers

struct FileCleanupView: View {
    @StateObject private var model = FileCleanupModel()
    @ObservedObject var history: CleanupHistory
    @State private var showingPicker = false
    @State private var plan: FileDeletionPlan?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose files in Files, then select the ones to delete. Only the files you choose are inspected.")
                    Button("Choose files") { showingPicker = true }
                        .disabled(model.isBusy)
                    Text("File sizes are not a promise of recovered device space. Cloud and external-drive files may use little or no space on this iPhone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.isBusy { ProgressView("Working…") }
                if let message = model.message { Text(message).foregroundStyle(.secondary) }
                Section {
                    ForEach(model.items) { item in
                        Button { model.toggle(item) } label: {
                            HStack {
                                Image(systemName: model.selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading) {
                                    Text(item.name).foregroundStyle(.primary)
                                    Text(item.location).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(StorageFormatting.bytes(item.bytes)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain).disabled(model.isBusy)
                        .accessibilityValue(model.selection.contains(item.id) ? Text("Selected") : Text("Not selected"))
                    }
                }
                if !history.receipts.isEmpty || history.errorMessage != nil {
                    Section { CleanupHistoryView(history: history) }
                }
            }
            .navigationTitle("Clean up files")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(model.isBusy) }
            }
            .safeAreaInset(edge: .bottom) {
                Button { plan = model.plan() } label: {
                    Text("Review selection (\(model.selection.count))").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).disabled(model.selection.isEmpty || model.isBusy)
                .padding().background(.regularMaterial)
            }
            .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await model.preview(urls) }
                case .failure: model.message = String(localized: "Files could not be opened. Try selecting them again.")
                }
            }
            .sheet(item: $plan) { selected in
                CleanupConfirmationView(
                    count: selected.items.count,
                    warning: "This deletes the selected files themselves. Cloud deletion may sync to other devices. Recovery depends on the file provider and may be impossible. Keep a separate copy of anything you need."
                ) {
                    ForEach(selected.items) { item in
                        VStack(alignment: .leading) {
                            Text(item.name)
                            Text(item.location).font(.caption).foregroundStyle(.secondary)
                            Text(StorageFormatting.bytes(item.bytes)).font(.caption)
                        }
                    }
                } confirm: {
                    Task { await model.delete(selected, history: history) }
                }
            }
        }
        .interactiveDismissDisabled(model.isBusy)
        .onDisappear { Task { await model.close() } }
    }
}
