import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var model = ModoreViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    storageSection
                    mediaSection
                    boundariesSection
                }
                .padding()
            }
            .navigationTitle("Modore")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh")
                }
            }
            .task { await model.refreshForViewLifetime() }
        }
    }

    @ViewBuilder
    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Device storage", systemImage: "internaldrive")
                .font(.headline)

            if let storage = model.storage {
                HStack(spacing: 12) {
                    StorageMetric(title: "Total", value: StorageFormatting.bytes(storage.totalBytes))
                    StorageMetric(title: "Used", value: StorageFormatting.bytes(storage.usedBytes))
                    StorageMetric(title: "Available", value: StorageFormatting.bytes(storage.availableBytes))
                }

                let deficit = storage.targetDeficitBytes
                if deficit > 0 {
                    Label("Available-space goal not met", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    HStack(spacing: 12) {
                        StorageMetric(
                            title: "Goal",
                            value: StorageFormatting.bytes(DeviceStorageSnapshot.targetBytes)
                        )
                        StorageMetric(title: "Space needed", value: StorageFormatting.bytes(deficit))
                    }
                } else {
                    Label("Available-space goal met", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } else {
                Text("Storage information is unavailable.")
                    .foregroundStyle(.secondary)
            }
        }
        .sectionCard()
    }

    @ViewBuilder
    private var mediaSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Photo library videos", systemImage: "photo.on.rectangle.angled")
                    .font(.headline)
                Spacer()
                if model.isScanning { ProgressView() }
            }

            Text("Modore reads public metadata only to count video and screen-recording durations.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if model.authorization == .authorized || model.authorization == .limited {
                HStack(spacing: 12) {
                    StorageMetric(title: "Videos", value: "\(model.media.videoCount)")
                    StorageMetric(title: "Total duration", value: DurationFormatting.string(model.media.videoDuration))
                }
                HStack(spacing: 12) {
                    StorageMetric(title: "Screen recordings", value: "\(model.media.screenRecordingCount)")
                    StorageMetric(title: "Recording duration", value: DurationFormatting.string(model.media.screenRecordingDuration))
                }

                if !model.media.longestVideos.isEmpty {
                    Text("Longest videos")
                        .font(.subheadline.weight(.semibold))
                    ForEach(model.media.longestVideos) { candidate in
                        HStack {
                            Image(systemName: candidate.isScreenRecording ? "rectangle.inset.filled" : "video")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading) {
                                Text(candidate.title)
                                if candidate.isScreenRecording { Text("Screen recording") .font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Text(DurationFormatting.string(candidate.duration))
                                .monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                } else {
                    Text("No videos are visible in the current photo-library scope.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(model.authorization.label)
                    .foregroundStyle(.secondary)
                if model.authorization == .denied {
                    Link("Open Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                        .buttonStyle(.borderedProminent)
                } else if model.authorization == .notDetermined {
                    Button("Allow photo access") {
                        model.requestPhotoAccess()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .sectionCard()
    }

    private var boundariesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Access boundaries", systemImage: "lock.shield")
                .font(.headline)
            Text("Modore can see the device storage summary and metadata for photo-library videos you allow.")
            Text("It cannot inspect other apps' caches, iOS System Data, or app sandboxes.")
            Text("This preview does not delete media. Use the Photos app when you decide to remove an item.")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .sectionCard()
    }
}

private struct StorageMetric: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    func sectionCard() -> some View {
        self.padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
