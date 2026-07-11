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

    init(
        sourceID: String,
        capturedAt: Date,
        freeGB: Double,
        usedGB: Double,
        totalGB: Double,
        items: [StorageHistoryItem]
    ) {
        self.sourceID = sourceID
        self.capturedAt = capturedAt
        self.freeGB = freeGB
        self.usedGB = usedGB
        self.totalGB = totalGB
        self.items = items
    }

    private static func items(_ values: [StorageItem], category: String) -> [StorageHistoryItem] {
        var indexed: [String: StorageHistoryItem] = [:]
        for item in values {
            let identity = historyIdentity(
                category: category,
                kind: item.kind,
                cleanupID: item.cleanupID,
                path: item.path
            )
            indexed[identity] = StorageHistoryItem(
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
        return indexed.values.sorted { $0.key < $1.key }
    }

    fileprivate static func historyIdentity(
        category: String,
        kind: String,
        cleanupID: String,
        path: String
    ) -> String {
        let recipe = cleanupID.isEmpty ? kind : cleanupID
        return "\(category)|\(recipe)|\(normalizedPath(path))"
    }

    fileprivate static func normalizedPath(_ path: String) -> String {
        guard !path.isEmpty else { return "<unknown>" }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        if normalized == "/" { return normalized }
        return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
    }
}

struct StorageItemChange: Identifiable, Equatable {
    let key: String
    let label: String
    let category: String
    let path: String
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
        let changes = Self.changes(previous: previous, current: current)
        let growing = changes.filter { $0.deltaGB >= 0.05 }.sorted { $0.deltaGB > $1.deltaGB }
        let shrinking = changes.filter { $0.deltaGB <= -0.05 }.sorted { $0.deltaGB < $1.deltaGB }
        let exclusive = Self.exclusiveRootChanges(changes)
        itemChanges = changes
        largestChanges = changes.sorted { abs($0.deltaGB) > abs($1.deltaGB) }
        growingItems = growing
        shrinkingItems = shrinking
        observedGrowthGB = exclusive.filter { $0.deltaGB >= 0.05 }.reduce(0) { $0 + $1.deltaGB }
        observedShrinkGB = exclusive.filter { $0.deltaGB <= -0.05 }.reduce(0) { $0 + abs($1.deltaGB) }
        trackedNetDeltaGB = exclusive.reduce(0) { $0 + $1.deltaGB }
    }

    private static func changes(
        previous: StorageHistoryEntry,
        current: StorageHistoryEntry
    ) -> [StorageItemChange] {
        let before = indexedItems(previous.items)
        let after = indexedItems(current.items)
        // Missing rows can mean that a bounded scan timed out. Compare rows present in both snapshots.
        let keys = Set(before.keys).intersection(after.keys)
        return keys.compactMap { key in
            guard let old = before[key], let row = after[key] else { return nil }
            if old.measureStatus == "timed_out" || row.measureStatus == "timed_out" {
                return nil
            }
            if old.sizeGB == 0, old.measureStatus == nil {
                return nil
            }
            guard abs(row.sizeGB - old.sizeGB) >= 0.05 else { return nil }
            return StorageItemChange(
                key: key,
                label: row.label,
                category: row.category,
                path: row.path,
                beforeGB: old.sizeGB,
                afterGB: row.sizeGB
            )
        }
    }

    private static func indexedItems(_ items: [StorageHistoryItem]) -> [String: StorageHistoryItem] {
        items.reduce(into: [:]) { result, item in
            let identity = StorageHistoryEntry.historyIdentity(
                category: item.category,
                kind: item.kind,
                cleanupID: item.cleanupID,
                path: item.path
            )
            // Historical files may contain the former recipe-only key more than once.
            // A path-bound identity preserves each real target; an exact duplicate is one target.
            result[identity] = item
        }
    }

    private static func exclusiveRootChanges(_ changes: [StorageItemChange]) -> [StorageItemChange] {
        let sorted = changes.sorted {
            if $0.category != $1.category { return $0.category < $1.category }
            return $0.path.count < $1.path.count
        }
        var roots: [StorageItemChange] = []
        for change in sorted {
            let path = StorageHistoryEntry.normalizedPath(change.path)
            let covered = roots.contains { root in
                guard root.category == change.category else { return false }
                let rootPath = StorageHistoryEntry.normalizedPath(root.path)
                return path == rootPath || path.hasPrefix(rootPath + "/")
            }
            if !covered {
                roots.append(change)
            }
        }
        return roots
    }
}

struct FreeSpaceSample: Identifiable, Equatable, Sendable {
    let checkedAt: Date
    let freeGB: Double
    let dropGB: Double
    let status: String

    var id: Date { checkedAt }
}

enum StorageHistoryStore {
    static let maximumEntries = 180
    static let maximumItemsPerEntry = 2_000
    static let maximumHistoryBytes = 16 * 1_024 * 1_024
    static let maximumSampleBytes = 4 * 1_024 * 1_024
    static let maximumSamples = 10_000

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
        (try? loadValidated(from: url)) ?? []
    }

    static func changeSummary(
        endingAt sourceID: String,
        in entries: [StorageHistoryEntry]
    ) -> StorageChangeSummary? {
        let sorted = entries.sorted { $0.capturedAt < $1.capturedAt }
        guard let currentIndex = sorted.firstIndex(where: { $0.sourceID == sourceID }),
              currentIndex > 0 else {
            return nil
        }
        return StorageChangeSummary(entries: [sorted[currentIndex - 1], sorted[currentIndex]])
    }

    static func newestEntry(
        after displayedEntry: StorageHistoryEntry?,
        in entries: [StorageHistoryEntry]
    ) -> StorageHistoryEntry? {
        guard let displayedEntry else { return nil }
        return entries
            .filter {
                $0.sourceID != displayedEntry.sourceID && $0.capturedAt > displayedEntry.capturedAt
            }
            .max { $0.capturedAt < $1.capturedAt }
    }

    @discardableResult
    static func record(
        _ entry: StorageHistoryEntry,
        at url: URL = historyURL
    ) throws -> [StorageHistoryEntry] {
        var entries = FileManager.default.fileExists(atPath: url.path)
            ? try loadValidated(from: url).filter { $0.sourceID != entry.sourceID }
            : []
        entries.append(sanitizedEntry(entry))
        entries.sort { $0.capturedAt < $1.capturedAt }
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
        }
        try secureWrite(entries, to: url)
        return entries
    }

    static func loadFreeSpaceSamples(from url: URL = sampleURL) -> [FreeSpaceSample] {
        guard let data = try? boundedData(contentsOf: url, maximumBytes: maximumSampleBytes),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).suffix(maximumSamples).compactMap { line in
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

    private static func sanitizedEntry(_ entry: StorageHistoryEntry) -> StorageHistoryEntry {
        guard entry.items.count > maximumItemsPerEntry else { return entry }
        return StorageHistoryEntry(
            sourceID: entry.sourceID,
            capturedAt: entry.capturedAt,
            freeGB: entry.freeGB,
            usedGB: entry.usedGB,
            totalGB: entry.totalGB,
            items: Array(entry.items.prefix(maximumItemsPerEntry))
        )
    }

    private static func loadValidated(from url: URL) throws -> [StorageHistoryEntry] {
        let data = try boundedData(contentsOf: url, maximumBytes: maximumHistoryBytes)
        let entries = try decoder.decode([StorageHistoryEntry].self, from: data)
        return entries
            .sorted { $0.capturedAt < $1.capturedAt }
            .suffix(maximumEntries)
            .map(sanitizedEntry)
    }

    private static func boundedData(contentsOf url: URL, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        return data
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
