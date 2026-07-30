import Darwin
import Foundation

struct LoadedScanResult: @unchecked Sendable {
    let content: ScanContent
    let storageHistory: [StorageHistoryEntry]
    let displayedStorageEntry: StorageHistoryEntry?
    let storageChange: StorageChangeSummary?
    let freeSpaceSamples: [FreeSpaceSample]
    let diagnostic: String?
}

enum ScanResultLoader {
    static let maximumScanResultBytes = 32 * 1_024 * 1_024

    static func load(
        projectRoot: URL,
        historyURL: URL = StorageHistoryStore.historyURL,
        sampleURL: URL = StorageHistoryStore.sampleURL
    ) -> LoadedScanResult {
        let scanURL = projectRoot.appendingPathComponent("scan_result.json")
        let scanParentIdentity = FilesystemIdentity.directory(at: projectRoot)
        let existingHistory = StorageHistoryStore.load(from: historyURL)
        let samples = StorageHistoryStore.loadFreeSpaceSamples(from: sampleURL)
        guard FileManager.default.fileExists(atPath: scanURL.path) else {
            return LoadedScanResult(
                content: .empty,
                storageHistory: existingHistory,
                displayedStorageEntry: nil,
                storageChange: nil,
                freeSpaceSamples: samples,
                diagnostic: nil
            )
        }

        let data: Data
        do {
            guard let scanParentIdentity else { throw ScanResultLoaderError.unreadable }
            data = try boundedData(
                contentsOf: scanURL,
                maximumBytes: maximumScanResultBytes,
                expectedParentIdentity: scanParentIdentity
            )
        } catch ScanResultLoaderError.tooLarge {
            return emptyResult(
                history: existingHistory,
                samples: samples,
                diagnostic: "검사 결과가 \(maximumScanResultBytes / 1_048_576)MB 제한을 넘어 읽지 않았습니다. 다시 검사하세요."
            )
        } catch {
            return emptyResult(
                history: existingHistory,
                samples: samples,
                diagnostic: "검사 결과를 읽지 못했습니다: \(error.localizedDescription)"
            )
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return emptyResult(
                history: existingHistory,
                samples: samples,
                diagnostic: "검사 결과 JSON이 올바르지 않아 표시하지 않았습니다. 다시 검사하세요."
            )
        }

        let content = ScanContent(root: root)
        guard let storage = content.storage else {
            return LoadedScanResult(
                content: content,
                storageHistory: existingHistory,
                displayedStorageEntry: nil,
                storageChange: nil,
                freeSpaceSamples: samples,
                diagnostic: nil
            )
        }

        let sourceText = JsonRead.string(root, "scannedAt")
        let fileDate = (try? scanURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        let capturedAt = scanDate(from: sourceText) ?? fileDate
        let sourceID = sourceText.isEmpty
            ? String(Int(capturedAt.timeIntervalSince1970))
            : sourceText
        let provisionalEntry = StorageHistoryEntry(
            sourceID: sourceID,
            capturedAt: capturedAt,
            storage: storage
        )
        // Compare against a provisional entry trimmed the same way stored entries
        // are, so the item cap cannot fabricate appeared/disappeared changes that
        // would mislabel the incident's storage-change attribution.
        let comparisonHistory = existingHistory.filter { $0.sourceID != sourceID }
            + [StorageHistoryStore.comparable(provisionalEntry)]
        let comparisonChange = StorageHistoryStore.changeSummary(
            endingAt: sourceID,
            in: comparisonHistory
        )
        let incident = IncidentAssessment.make(
            content: content,
            storageChange: comparisonChange
        )
        let entry = StorageHistoryEntry(
            sourceID: sourceID,
            capturedAt: capturedAt,
            storage: storage,
            incident: incident,
            collectionComplete: content.collectionCoverage?.complete,
            evidence: IncidentEvidenceSnapshot(content: content)
        )

        do {
            let history = try StorageHistoryStore.record(entry, at: historyURL)
            return LoadedScanResult(
                content: content,
                storageHistory: history,
                displayedStorageEntry: entry,
                storageChange: StorageHistoryStore.changeSummary(endingAt: sourceID, in: history),
                freeSpaceSamples: samples,
                diagnostic: nil
            )
        } catch {
            return LoadedScanResult(
                content: content,
                storageHistory: existingHistory,
                displayedStorageEntry: entry,
                storageChange: StorageHistoryStore.changeSummary(
                    endingAt: sourceID,
                    in: existingHistory.filter { $0.sourceID != sourceID } + [entry]
                ),
                freeSpaceSamples: samples,
                diagnostic: "저장공간 이력을 기록하지 못했습니다: \(error.localizedDescription)"
            )
        }
    }

    static func boundedData(
        contentsOf url: URL,
        maximumBytes: Int,
        expectedParentIdentity: FilesystemIdentity? = nil
    ) throws -> Data {
        do {
            return try SecureLocalFileIO.boundedRead(
                from: url,
                maximumBytes: maximumBytes,
                requireCurrentOwner: true,
                expectedParentIdentity: expectedParentIdentity
            )
        } catch let error as NSError where error.code == Int(EFBIG) {
            throw ScanResultLoaderError.tooLarge
        } catch {
            throw ScanResultLoaderError.unreadable
        }
    }

    private static func emptyResult(
        history: [StorageHistoryEntry],
        samples: [FreeSpaceSample],
        diagnostic: String
    ) -> LoadedScanResult {
        LoadedScanResult(
            content: .empty,
            storageHistory: history,
            displayedStorageEntry: nil,
            storageChange: nil,
            freeSpaceSamples: samples,
            diagnostic: diagnostic
        )
    }

    private static func scanDate(from value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }
}

enum ScanResultLoaderError: Error {
    case tooLarge
    case unreadable
}
