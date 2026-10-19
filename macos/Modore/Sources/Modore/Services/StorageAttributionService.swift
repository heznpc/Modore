import Darwin
import Foundation

/// Both app entry points share this collector; Python is not part of the execution path.
enum StorageAttributionService {
    static let explainArgument = "--storage-explain"
    static let workerArgument = "--storage-attribution-worker"
    typealias Worker = (StorageAttribution.Request) async throws -> StorageAttribution.Response

    static func run(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        state: URL = StorageHistoryStore.stateDirectory,
        since: TimeInterval? = nil,
        targets: [(String, String)]? = nil,
        worker: Worker = measure
    ) async throws -> StorageAttribution.Report {
        let now = Date().timeIntervalSince1970
        let samples = try? SecureLocalFileIO.boundedRead(from: state.appendingPathComponent("storage-samples.tsv"),
                                                        maximumBytes: 8_000_000, requireCurrentOwner: true)
        let text = samples.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let (start, freeBefore) = StorageAttribution.baseline(text: text, since: since, now: now)
        let previous = StorageAttribution.pastMeasurements(state: state, since: start)
        let recent = StorageAttribution.pastMeasurements(state: state, since: now, maxAge: 30 * 86400)
        let selected = targets ?? StorageAttribution.roots(home: home)
        var rows: [StorageAttribution.Row] = []
        var seen = Set<StorageAttribution.Identity>()
        for (label, path) in selected {
            try Task.checkCancellation()
            let response = try await worker(.init(label: label, path: path, since: start, now: now, seen: seen))
            try Task.checkCancellation()
            seen.formUnion(response.identities)
            var row = response.row
            let key = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            let old = previous[key], latest = recent[key]
            row.previousMeasuredAt = latest.map { StorageAttribution.iso($0.at) }
            row.recentDeltaBytes = row.complete ? latest.map { row.allocatedBytes - $0.bytes } : nil
            row.baselineBytes = old?.bytes
            row.measuredDeltaBytes = row.complete ? old.map { row.allocatedBytes - $0.bytes } : nil
            row.measuredAt = StorageAttribution.iso(Date().timeIntervalSince1970)
            rows.append(row)
            let progress: [String: Any] = ["startedAt": StorageAttribution.iso(now), "completed": rows.count,
                                           "total": selected.count, "label": label]
            try SecureLocalFileIO.atomicWrite(JSONSerialization.data(withJSONObject: progress),
                                             to: state.appendingPathComponent("storage-explanation-progress.json"))
        }
        try Task.checkCancellation()
        var filesystem = statvfs()
        guard statvfs(home.path, &filesystem) == 0 else { throw POSIXError(.EIO) }
        let freeNow = Int64(filesystem.f_bavail) * Int64(filesystem.f_frsize)
        let report = StorageAttribution.Report(
            capturedAt: StorageAttribution.iso(Date().timeIntervalSince1970),
            scanStartedAt: StorageAttribution.iso(now), since: StorageAttribution.iso(start),
            baselineFreeBytes: freeBefore, freeBytes: freeNow,
            freeDropBytes: freeBefore.map { max(0, $0 - freeNow) },
            rows: rows.sorted { $0.createdBytes > $1.createdBytes })
        let data = try JSONEncoder().encode(report)
        guard data.count <= 8_000_000 else { throw CocoaError(.fileReadTooLarge) }
        try Task.checkCancellation()
        try SecureLocalFileIO.atomicWrite(data, to: state.appendingPathComponent("storage-explanations/\(UUID().uuidString).json"))
        try SecureLocalFileIO.atomicWrite(data, to: state.appendingPathComponent("storage-explanation.json"))
        return report
    }

    static func measure(_ request: StorageAttribution.Request) async throws -> StorageAttribution.Response {
        guard let executable = Bundle.main.executableURL else { throw CocoaError(.executableNotLoadable) }
        return try await measure(request, executable: executable,
            signedBundle: Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil)
    }

    static func measure(_ request: StorageAttribution.Request, executable: URL,
                        signedBundle: URL? = nil, timeout: TimeInterval = 30) async throws -> StorageAttribution.Response {
        let result = await LocalProcessRunner.capture(executable: executable.path,
            arguments: [workerArgument, "@pch-pinned:attribution"],
            currentDirectory: URL(fileURLWithPath: "/"),
            expectedSignedBundleURL: signedBundle,
            pinnedFiles: ["attribution": try JSONEncoder().encode(request)],
            timeout: timeout, maxOutputBytes: 8_000_000, waitForCleanupOnStop: true)
        try Task.checkCancellation()
        if result.succeeded,
           let response = try? JSONDecoder().decode(StorageAttribution.Response.self, from: Data(result.output.utf8)) {
            return response
        }
        var row = StorageAttribution.Row(label: request.label, path: request.path)
        row.errors = 1; row.complete = false
        row.status = result.endState == .timedOut ? "timeout" : "failed"
        return .init(row: row, identities: [])
    }

    @MainActor static func runCLIAndExit(arguments: [String]) -> Never {
        let options = Array(arguments.dropFirst(2))
        var since: TimeInterval?
        if !options.isEmpty {
            guard options.count == 2, options[0] == "--since",
                  let timestamp = StorageAttribution.timestamp(options[1]) else {
                FileHandle.standardError.write(Data("Usage: modore storage explain [--since ISO-TIMESTAMP]\n".utf8))
                exit(64)
            }
            since = timestamp
        }
        let start = since
        Task {
            do {
                let report = try await run(since: start)
                FileHandle.standardOutput.write(try JSONEncoder().encode(report))
                FileHandle.standardOutput.write(Data("\n".utf8))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Storage attribution failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(1)
    }

    /// Dispatched before SwiftUI state, singleton coordination or background services are created.
    static func runWorkerAndExit(arguments: [String]) -> Never {
        do {
            guard arguments.count == 3 else { throw CocoaError(.fileReadInvalidFileName) }
            let data = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
            let request = try JSONDecoder().decode(StorageAttribution.Request.self, from: data)
            guard request.path.hasPrefix("/"), request.since.isFinite, request.now.isFinite else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let response = StorageAttribution.scan(request)
            FileHandle.standardOutput.write(try JSONEncoder().encode(response))
            exit(0)
        } catch { exit(1) }
    }
}
