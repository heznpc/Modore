import Photos
import SwiftUI

struct PhotoCleanupView: View {
    @StateObject private var model = PhotoCleanupModel()
    @ObservedObject var history: CleanupHistory
    @State private var filter: CleanupMediaFilter = .videos
    @State private var plan: MediaDeletionPlan?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Media type", selection: $filter) {
                        ForEach(CleanupMediaFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isDeleting)
                    Text("Up to 200 items: longest videos or newest photos. Duration does not indicate file size.")
                        .font(.caption).foregroundStyle(.secondary)
                    if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited {
                        Text("Selected photos only").font(.caption).foregroundStyle(.orange)
                        Button("Manage photo access") { openSettings() }
                    }
                }
                if model.isLoading || model.isDeleting {
                    ProgressView(model.isDeleting ? "Deleting…" : "Loading…")
                }
                if let error = model.errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red)
                        Button("Reload") { Task { await model.load(filter: filter) } }
                            .disabled(model.isDeleting)
                    }
                }
                Section {
                    if model.items.isEmpty && !model.isLoading {
                        Text("No items are visible with the current filter and permission.")
                    }
                    ForEach(model.items) { item in
                        Button { model.toggle(item) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: model.selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                CleanupMediaRow(item: item)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!item.canDelete || model.isDeleting)
                        .accessibilityValue(model.selection.contains(item.id) ? Text("Selected") : Text("Not selected"))
                    }
                }
                if !history.receipts.isEmpty || history.errorMessage != nil {
                    Section { CleanupHistoryView(history: history) }
                }
            }
            .navigationTitle("Clean up photos & videos")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.disabled(model.isDeleting)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { plan = model.plan() } label: {
                    Text("Review selection (\(model.selection.count))").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selection.isEmpty || model.isDeleting || model.isLoading)
                .padding().background(.regularMaterial)
            }
            .sheet(item: $plan) { selected in
                CleanupConfirmationView(
                    count: selected.items.count,
                    warning: "These items will move to Recently Deleted. With iCloud Photos, deletion also syncs to your other devices. To finish removing them, review Recently Deleted in Photos. Modore cannot empty it for you."
                ) {
                    ForEach(selected.items) { CleanupMediaRow(item: $0) }
                } confirm: {
                    Task { await model.delete(selected, history: history, filter: filter) }
                }
            }
            .task(id: filter) { await model.load(filter: filter) }
            .onChange(of: scenePhase) { _, phase in
                // Do not clear a reviewed selection on the system deletion alert.
                // The service independently revalidates permission and contents.
                if phase == .active && !model.isDeleting && plan == nil {
                    Task { await model.load(filter: filter) }
                }
            }
        }
        .interactiveDismissDisabled(model.isDeleting)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct CleanupMediaRow: View {
    let item: CleanupMediaItem
    var body: some View {
        HStack(spacing: 12) {
            CleanupThumbnail(assetID: item.id, isVideo: item.isVideo)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).foregroundStyle(.primary)
                if item.isVideo {
                    Text(DurationFormatting.string(item.duration)).font(.caption).foregroundStyle(.secondary)
                }
                if item.isFavorite { Label("Favorite", systemImage: "heart.fill").font(.caption).foregroundStyle(.orange) }
                if !item.canDelete { Text("Cannot delete this item").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct CleanupThumbnail: View {
    let assetID: String
    let isVideo: Bool
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?
    @State private var generation = UUID()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: isVideo ? "video" : "photo").foregroundStyle(.secondary) }
        }
        .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
        .onAppear {
            let token = UUID()
            generation = token
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else { return }
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            requestID = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 160, height: 160),
                                                             contentMode: .aspectFill, options: options) { result, _ in
                Task { @MainActor in
                    if generation == token { image = result }
                }
            }
        }
        .onDisappear {
            generation = UUID()
            if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
            requestID = nil
        }
    }
}
