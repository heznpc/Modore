import Foundation

struct StorageHistoryItem: Codable, Identifiable, Equatable {
    let key: String
    let label: String
    let category: String
    let kind: String
    let sizeGB: Double
    let path: String
    let cleanupID: String
    let measureStatus: String?

    var id: String { key }
}

struct StorageHistoryEntry: Codable, Identifiable, Equatable {
    let sourceID: String
    let capturedAt: Date
    let freeGB: Double
    let usedGB: Double
    let totalGB: Double
    let items: [StorageHistoryItem]

    var id: String { sourceID }

    init(sourceID: String, capturedAt: Date, storage: StorageSnapshot) {
        self.sourceID = sourceID
        self.capturedAt = capturedAt
        freeGB = storage.freeGB
        usedGB = storage.usedGB
        totalGB = storage.totalGB

        var rows: [StorageHistoryItem] = []
        rows += Self.items(storage.cleanupCandidates, category: "cleanup")
        rows += Self.items(storage.reviewCandidates, category: "review")
        rows += Self.items(storage.developerToolchains, category: "developer")
        self.items = rows
    }

    private static func items(_ values: [StorageItem], category: String) -> [StorageHistoryItem] {
        values.map { item in
            let identity = item.cleanupID.isEmpty
                ? "\(category)|\(item.kind)|\(item.path)"
                : "\(category)|\(item.cleanupID)"
            return StorageHistoryItem(
                key: identity,
                label: item.label,
                category: category,
                kind: item.kind,
                sizeGB: item.sizeGB,
                path: item.path,
                cleanupID: item.cleanupID,
                measureStatus: item.measureStatus
            )
        }
    }
}

struct StorageItemChange: Identifiable, Equatable {
    let key: String
    let label: String
    let category: String
    let beforeGB: Double
    let afterGB: Double

    var id: String { key }
    var deltaGB: Double { afterGB - beforeGB }
}

struct StorageChangeSummary: Equatable {
    let previous: StorageHistoryEntry
    let current: StorageHistoryEntry
    let itemChanges: [StorageItemChange]
    let largestChanges: [StorageItemChange]
    let growingItems: [StorageItemChange]
    let shrinkingItems: [StorageItemChange]
    let observedGrowthGB: Double
    let observedShrinkGB: Double
    let trackedNetDeltaGB: Double

    var freeDeltaGB: Double { current.freeGB - previous.freeGB }
    var consumedGB: Double { max(0, -freeDeltaGB) }
    var recoveredGB: Double { max(0, freeDeltaGB) }

    var unattributedConsumedGB: Double {
        max(0, consumedGB - observedGrowthGB)
    }

    var unattributedRecoveredGB: Double {
        max(0, recoveredGB - observedShrinkGB)
    }

    init?(entries: [StorageHistoryEntry]) {
        guard entries.count >= 2 else { return nil }
        let sorted = entries.sorted { $0.capturedAt < $1.capturedAt }
        previous = sorted[sorted.count - 2]
        current = sorted[sorted.count - 1]

        let before = Dictionary(uniqueKeysWithValues: previous.items.map { ($0.key, $0) })
        let after = Dictionary(uniqueKeysWithValues: current.items.map { ($0.key, $0) })
        // A missing row can mean that the bounded scanner ran out of time, not that
        // the path was created or deleted. Compare only measurements present in both snapshots.
        let keys = Set(before.keys).intersection(after.keys)
        let changes: [StorageItemChange] = keys.compactMap { key in
            guard let old = before[key], let row = after[key] else { return nil }
            if before[key]?.measureStatus == "timed_out" || after[key]?.measureStatus == "timed_out" {
                return nil
            }
            if old.sizeGB == 0, old.measureStatus == nil {
                return nil
            }
            let oldSize = old.sizeGB
            let newSize = row.sizeGB
            guard abs(newSize - oldSize) >= 0.05 else { return nil }
            return StorageItemChange(
                key: key,
                label: row.label,
                category: row.category,
                beforeGB: oldSize,
                afterGB: newSize
            )
        }
        let growing = changes.filter { $0.deltaGB >= 0.05 }.sorted { $0.deltaGB > $1.deltaGB }
        let shrinking = changes.filter { $0.deltaGB <= -0.05 }.sorted { $0.deltaGB < $1.deltaGB }
        itemChanges = changes
        largestChanges = changes.sorted { abs($0.deltaGB) > abs($1.deltaGB) }
        growingItems = growing
        shrinkingItems = shrinking
        observedGrowthGB = growing.reduce(0) { $0 + $1.deltaGB }
        observedShrinkGB = shrinking.reduce(0) { $0 + abs($1.deltaGB) }
        trackedNetDeltaGB = changes.reduce(0) { $0 + $1.deltaGB }
    }
}

struct FreeSpaceSample: Identifiable, Equatable {
    let checkedAt: Date
    let freeGB: Double
    let dropGB: Double
    let status: String

    var id: Date { checkedAt }
}

enum StorageHistoryStore {
    static let maximumEntries = 180

    static var stateDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PC Health Check")
    }

    static var historyURL: URL {
        stateDirectory.appendingPathComponent("storage-history.json")
    }

    static var sampleURL: URL {
        stateDirectory.appendingPathComponent("storage-samples.tsv")
    }

    static func load(from url: URL = historyURL) -> [StorageHistoryEntry] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? decoder.decode([StorageHistoryEntry].self, from: data) else {
            return []
        }
        return entries.sorted { $0.capturedAt < $1.capturedAt }
    }

    @discardableResult
    static func record(
        _ entry: StorageHistoryEntry,
        at url: URL = historyURL
    ) throws -> [StorageHistoryEntry] {
        var entries = load(from: url).filter { $0.sourceID != entry.sourceID }
        entries.append(entry)
        entries.sort { $0.capturedAt < $1.capturedAt }
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
        }
        try secureWrite(entries, to: url)
        return entries
    }

    static func loadFreeSpaceSamples(from url: URL = sampleURL) -> [FreeSpaceSample] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 4,
                  let date = try? isoFormat.parse(String(fields[0])),
                  let freeKB = Double(fields[1]),
                  let dropKB = Double(fields[2]) else {
                return nil
            }
            return FreeSpaceSample(
                checkedAt: date,
                freeGB: freeKB / 1_048_576,
                dropGB: dropKB / 1_048_576,
                status: String(fields[3])
            )
        }.sorted { $0.checkedAt < $1.checkedAt }
    }

    private static func secureWrite(_ entries: [StorageHistoryEntry], to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try encoder.encode(entries)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let isoFormat = Date.ISO8601FormatStyle()
}
