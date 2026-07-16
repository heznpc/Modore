import Foundation

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
        guard let parentIdentity = FilesystemIdentity.directory(
            at: url.deletingLastPathComponent()
        ) else { return [] }
        return (try? loadValidated(from: url, expectedParentIdentity: parentIdentity)) ?? []
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
        let parent = url.deletingLastPathComponent()
        try SecureLocalFileIO.ensurePrivateDirectory(parent)
        guard let parentIdentity = FilesystemIdentity.directory(at: parent) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var entries = FileManager.default.fileExists(atPath: url.path)
            ? try loadValidated(
                from: url,
                expectedParentIdentity: parentIdentity
              ).filter { $0.sourceID != entry.sourceID }
            : []
        entries.append(sanitizedEntry(entry))
        entries.sort { $0.capturedAt < $1.capturedAt }
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
        }
        return try secureWrite(entries, to: url, expectedParentIdentity: parentIdentity)
    }

    static func loadFreeSpaceSamples(from url: URL = sampleURL) -> [FreeSpaceSample] {
        guard let parentIdentity = FilesystemIdentity.directory(
            at: url.deletingLastPathComponent()
        ),
              let data = try? boundedData(
                contentsOf: url,
                maximumBytes: maximumSampleBytes,
                expectedParentIdentity: parentIdentity
              ),
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

    private static func secureWrite(
        _ entries: [StorageHistoryEntry],
        to url: URL,
        expectedParentIdentity: FilesystemIdentity
    ) throws -> [StorageHistoryEntry] {
        let payload = try encodedHistoryForWrite(entries)
        try SecureLocalFileIO.atomicWrite(
            payload.data,
            to: url,
            permissions: 0o600,
            expectedParentIdentity: expectedParentIdentity
        )
        return payload.entries
    }

    static func encodedHistoryForWrite(
        _ entries: [StorageHistoryEntry],
        maximumBytes: Int = maximumHistoryBytes
    ) throws -> (entries: [StorageHistoryEntry], data: Data) {
        guard maximumBytes > 0 else { throw CocoaError(.fileWriteOutOfSpace) }
        var retained = Array(
            entries
                .sorted { $0.capturedAt < $1.capturedAt }
                .suffix(maximumEntries)
                .map(sanitizedEntry)
        )
        var data = try encoder.encode(retained)

        while data.count > maximumBytes, retained.count > 2 {
            retained.removeFirst()
            data = try encoder.encode(retained)
        }
        guard data.count > maximumBytes else { return (retained, data) }

        let originals = retained
        var lowerBound = 0
        var upperBound = originals.map { $0.items.count }.max() ?? 0
        var best: (entries: [StorageHistoryEntry], data: Data)?
        while lowerBound <= upperBound {
            let itemLimit = lowerBound + (upperBound - lowerBound) / 2
            let candidate = originals.map { entry($0, keepingAtMost: itemLimit) }
            let candidateData = try encoder.encode(candidate)
            if candidateData.count <= maximumBytes {
                best = (candidate, candidateData)
                lowerBound = itemLimit + 1
            } else {
                upperBound = itemLimit - 1
            }
        }
        if let best { return best }

        var metadataOnly = originals.map { entry($0, keepingAtMost: 0) }
        var metadataData = try encoder.encode(metadataOnly)
        while metadataData.count > maximumBytes, metadataOnly.count > 1 {
            metadataOnly.removeFirst()
            metadataData = try encoder.encode(metadataOnly)
        }
        guard metadataData.count <= maximumBytes else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        return (metadataOnly, metadataData)
    }

    private static func sanitizedEntry(_ entry: StorageHistoryEntry) -> StorageHistoryEntry {
        guard entry.items.count > maximumItemsPerEntry else { return entry }
        return self.entry(entry, keepingAtMost: maximumItemsPerEntry)
    }

    private static func entry(
        _ entry: StorageHistoryEntry,
        keepingAtMost itemCount: Int
    ) -> StorageHistoryEntry {
        guard entry.items.count > itemCount else { return entry }
        return StorageHistoryEntry(
            sourceID: entry.sourceID,
            capturedAt: entry.capturedAt,
            freeGB: entry.freeGB,
            usedGB: entry.usedGB,
            totalGB: entry.totalGB,
            items: Array(entry.items.prefix(max(0, itemCount))),
            freeSpaceMeasured: entry.freeSpaceMeasured,
            incidentKind: entry.incidentKind,
            incidentTitle: entry.incidentTitle,
            incidentValue: entry.incidentValue,
            collectionComplete: entry.collectionComplete,
            browserVerdict: entry.browserVerdict,
            evidence: entry.evidence
        )
    }

    private static func loadValidated(
        from url: URL,
        expectedParentIdentity: FilesystemIdentity
    ) throws -> [StorageHistoryEntry] {
        let data = try boundedData(
            contentsOf: url,
            maximumBytes: maximumHistoryBytes,
            expectedParentIdentity: expectedParentIdentity
        )
        let entries = try decoder.decode([StorageHistoryEntry].self, from: data)
        return entries
            .sorted { $0.capturedAt < $1.capturedAt }
            .suffix(maximumEntries)
            .map(sanitizedEntry)
    }

    private static func boundedData(
        contentsOf url: URL,
        maximumBytes: Int,
        expectedParentIdentity: FilesystemIdentity
    ) throws -> Data {
        try SecureLocalFileIO.boundedRead(
            from: url,
            maximumBytes: maximumBytes,
            requireCurrentOwner: true,
            expectedParentIdentity: expectedParentIdentity
        )
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
