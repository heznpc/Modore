import XCTest
@testable import PCHealthCheckMac

final class IncidentAssessmentTests: XCTestCase {
    func testIncompleteRequiredCollectionPreventsClearAssessment() throws {
        let content = ScanContent(root: root(
            collection: [
                "status": "incomplete",
                "complete": false,
                "completedCount": 1,
                "sourceCount": 2,
                "completedRequiredCount": 1,
                "requiredCount": 2,
                "sources": [
                    source("cpu_processes", "실행 프로세스", "ok", true),
                    source("network_connections", "외부 네트워크 연결", "permission_denied", true),
                ],
            ]
        ))

        let assessment = IncidentAssessment.make(content: content, storageChange: nil)

        XCTAssertEqual(assessment.kind, .collectionIncomplete)
        XCTAssertTrue(assessment.title.contains("판단을 보류"))
        XCTAssertEqual(content.collectionCoverage?.requiredIssues.count, 1)
    }

    func testSystemChromeAutomationBecomesPrimaryIncident() throws {
        var value = root(collection: completeCollection())
        var sections = try XCTUnwrap(value["sections"] as? [String: Any])
        var storage = try XCTUnwrap(sections["storage"] as? [String: Any])
        storage["browserAutomation"] = [
            "verdict": "conflict_possible",
            "rootCount": 1,
            "systemRootCount": 1,
            "isolatedRootCount": 0,
            "orphanedRootCount": 0,
            "globalConfigPresent": false,
            "globalIsolationConfigured": false,
            "isolatedBrowserInstalled": true,
            "configLocation": "~/.playwright/cli.config.json",
            "note": "자동화가 기본 Chrome 채널을 사용합니다.",
        ]
        storage["runtimeSignals"] = [[
            "kind": "browser_automation_root",
            "label": "시스템 Chrome 자동화",
            "count": 1,
            "risk": "warning",
            "action": "자동화 종료 후 기본 Chrome 다시 열기",
            "note": "PID 123 · 부모 PID 10",
            "pid": 123,
            "parentPid": 10,
            "elapsed": "01:12:00",
            "channel": "system",
            "state": "active",
            "profile": "temporary",
            "controller": "Codex",
        ]]
        sections["storage"] = storage
        value["sections"] = sections

        let content = ScanContent(root: value)
        let assessment = IncidentAssessment.make(content: content, storageChange: nil)

        XCTAssertEqual(assessment.kind, .browserAutomation)
        XCTAssertTrue(assessment.detail.contains("기본 Chrome"))
        XCTAssertEqual(content.storage?.runtimeSignals.first?.pid, 123)
        XCTAssertEqual(content.storage?.runtimeSignals.first?.controller, "Codex")
    }

    func testClearAssessmentNamesCompletedRequiredScope() {
        let content = ScanContent(root: root(collection: completeCollection()))

        let assessment = IncidentAssessment.make(content: content, storageChange: nil)

        XCTAssertEqual(assessment.kind, .clear)
        XCTAssertTrue(assessment.detail.contains("2/2"))
    }

    func testIncidentMetadataRoundTripsWithStorageHistory() throws {
        let content = ScanContent(root: root(collection: completeCollection()))
        let storage = try XCTUnwrap(content.storage)
        let incident = IncidentAssessment.make(content: content, storageChange: nil)
        let entry = StorageHistoryEntry(
            sourceID: "test-scan",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            storage: storage,
            incident: incident,
            collectionComplete: true,
            evidence: IncidentEvidenceSnapshot(content: content)
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(StorageHistoryEntry.self, from: data)

        XCTAssertEqual(decoded.incidentKind, "clear")
        XCTAssertEqual(decoded.incidentTitle, incident.title)
        XCTAssertEqual(decoded.collectionComplete, true)
        XCTAssertEqual(decoded.browserVerdict, "clear")
        XCTAssertEqual(decoded.evidence?.processCount, 0)
        XCTAssertEqual(decoded.evidence?.listeningPortCount, 0)
    }

    func testLegacyStorageHistoryWithoutIncidentMetadataStillDecodes() throws {
        let legacy: [String: Any] = [
            "sourceID": "legacy",
            "capturedAt": 721_692_800.0,
            "freeGB": 20.0,
            "usedGB": 200.0,
            "totalGB": 220.0,
            "items": [],
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate

        let decoded = try decoder.decode(StorageHistoryEntry.self, from: data)

        XCTAssertNil(decoded.incidentKind)
        XCTAssertNil(decoded.collectionComplete)
        XCTAssertNil(decoded.evidence)
    }

    func testHistoryItemPruningRetainsEvidenceCounts() throws {
        let items = (0...StorageHistoryStore.maximumItemsPerEntry).map { index in
            StorageHistoryItem(
                key: "item-\(index)",
                label: "Item \(index)",
                category: "review",
                kind: "test",
                sizeGB: 1,
                path: "/test/\(index)",
                cleanupID: "",
                measureStatus: "ok"
            )
        }
        let evidence = IncidentEvidenceSnapshot(content: ScanContent(root: [
            "findings": [["level": "warning"]],
            "sections": [
                "cpu": [["name": "test"]],
                "network": [["process": "test"]],
                "listeningPorts": [["name": "test"]],
            ],
        ]))
        let entry = StorageHistoryEntry(
            sourceID: "oversized",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            freeGB: 10,
            usedGB: 20,
            totalGB: 30,
            items: items,
            evidence: evidence
        )

        let encoded = try StorageHistoryStore.encodedHistoryForWrite([entry])

        XCTAssertEqual(encoded.entries.first?.items.count, StorageHistoryStore.maximumItemsPerEntry)
        XCTAssertEqual(encoded.entries.first?.evidence, evidence)
    }

    private func root(collection: [String: Any]) -> [String: Any] {
        [
            "summary": [
                "overall": "safe",
                "dangerCount": 0,
                "warningCount": 0,
                "collectionComplete": collection["complete"] as? Bool ?? false,
                "message": "현재 수집 범위에서 뚜렷한 이상 징후가 발견되지 않았습니다.",
            ],
            "collection": collection,
            "findings": [],
            "sections": [
                "storage": [
                    "volume": [
                        "mount": "/System/Volumes/Data",
                        "freeGB": 45.0,
                        "usedGB": 200.0,
                        "totalGB": 245.0,
                        "usePercent": 82.0,
                        "risk": "safe",
                    ],
                    "runtimeSignals": [],
                    "browserAutomation": [
                        "verdict": "clear",
                        "rootCount": 0,
                        "systemRootCount": 0,
                        "isolatedRootCount": 0,
                        "orphanedRootCount": 0,
                        "globalConfigPresent": false,
                        "globalIsolationConfigured": false,
                        "isolatedBrowserInstalled": false,
                        "configLocation": "~/.playwright/cli.config.json",
                        "note": "현재 브라우저 자동화 루트가 감지되지 않았습니다.",
                    ],
                ],
            ],
        ]
    }

    private func completeCollection() -> [String: Any] {
        [
            "status": "complete",
            "complete": true,
            "completedCount": 2,
            "sourceCount": 2,
            "completedRequiredCount": 2,
            "requiredCount": 2,
            "sources": [
                source("cpu_processes", "실행 프로세스", "ok", true),
                source("network_connections", "외부 네트워크 연결", "ok", true),
            ],
        ]
    }

    private func source(
        _ id: String,
        _ label: String,
        _ status: String,
        _ required: Bool
    ) -> [String: Any] {
        [
            "id": id,
            "label": label,
            "status": status,
            "required": required,
            "detail": "test",
        ]
    }
}
