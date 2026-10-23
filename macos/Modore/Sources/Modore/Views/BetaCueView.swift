import SwiftUI

struct BetaCueView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var state: BetaCueReadState = .missing
    @State private var reading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("BetaCue", systemImage: "shippingbox").font(.title2.bold())
                Spacer()
                Link("Open BetaCue", destination: URL(string: "betacue://watch")!)
                Button("Refresh") { Task { await refresh() } }.disabled(reading)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TimelineView(.periodic(from: .now, by: 5)) { context in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        content(now: context.date)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(22).frame(minWidth: 680, idealWidth: 800, minHeight: 500)
        .task {
            repeat {
                await refresh()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { break }
            } while !Task.isCancelled
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        switch state {
        case .missing:
            Text("Open BetaCue to view its current watch and linked work records here.").foregroundStyle(.secondary)
        case .invalid:
            Label("BetaCue’s shared status cannot be read. Open BetaCue and try again.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .available(let snapshot):
            if snapshot.runtime.state == "stopped" {
                Label("BetaCue has stopped. These are its last saved results.", systemImage: "pause.circle")
                    .foregroundStyle(.orange)
            } else if !snapshot.isCurrent(now: now) {
                Label("These results are out of date. Current watch status is unknown.", systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.orange)
            }
            Text("Shared \(snapshot.generatedAt.formatted(date: .abbreviated, time: .standard))")
                .font(.caption).foregroundStyle(.secondary)
            if !snapshot.issues.isEmpty {
                Label("BetaCue reports a monitoring issue. Open BetaCue to review it.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if let watch = snapshot.watch { watchSection(watch) }
            else { Text("No active upload watch.").foregroundStyle(.secondary) }
            ForEach(snapshot.apps) { app in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(app.name).font(.headline)
                        if let build = app.latestBuild { Text(build.displayVersion).foregroundStyle(.secondary) }
                    }
                    Text(app.status.headline)
                    Text(app.status.description).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    if app.partial { Label("Some observations are unavailable.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    Text("Observed \(app.fetchedAt.formatted(date: .abbreviated, time: .standard))").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
            }
            if !snapshot.workRecords.isEmpty {
                Text("Linked work records").font(.headline)
                ForEach(snapshot.workRecords) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        if let destination = record.destination { Link(record.title, destination: destination) }
                        else { Text(record.title) }
                        if let project = record.projectPath { Text(project).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                }
            }
        }
    }

    private func watchSection(_ watch: BetaCueSnapshot.Watch) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(watch.appName).font(.headline)
            Text(watch.headline).font(.title3)
            if !watch.detail.isEmpty { Text(watch.detail).foregroundStyle(.secondary).textSelection(.enabled) }
            if let observedAt = watch.observedAt {
                Text("Observed \(observedAt.formatted(date: .abbreviated, time: .standard))").font(.caption).foregroundStyle(.secondary)
            }
            if let build = watch.buildID { Text("Target build: \(build)").font(.caption).textSelection(.enabled) }
            if let group = watch.goal.groupName ?? watch.goal.groupID { Text("Target group: \(group)").font(.callout) }
            else { Text(watch.goal.channel == "internal" ? "Internal testing" : watch.goal.channel == "external" ? "External testing" : "Any testing channel").font(.callout) }
            ForEach(Array(watch.evidence.enumerated()), id: \.offset) { _, evidence in Text(evidence).font(.callout).textSelection(.enabled) }
            if let destination = watch.destination { Link("Open watch in BetaCue", destination: destination) }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    @MainActor private func refresh() async {
        guard !reading else { return }
        reading = true
        defer { reading = false }
        let result = await Task.detached(priority: .utility) { BetaCueStateService.read() }.value
        guard !Task.isCancelled else { return }
        state = result
    }
}
