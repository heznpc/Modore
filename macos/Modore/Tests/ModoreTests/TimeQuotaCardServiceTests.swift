import XCTest
@testable import Modore

final class TimeQuotaCardServiceTests: XCTestCase {
    /// Synthetic quota boundary fixture covers nullable errors, fractional timestamps, mixed numeric percentages, and a non-Git workspace name.
    private let realShape = """
    {
      "schemaVersion": 2,
      "generatedAt": "2000-01-01T12:00:00.100Z",
      "collection": {
        "lastSampleAt": "2000-01-01T12:00:01.200Z",
        "healthy": true,
        "providers": { "codex": "recent-success", "claude": "never-attempted" }
      },
      "window": { "provider": "codex", "usedPercent": 60, "resetsAt": "2000-01-05T12:00:00.000Z" },
      "headline": {
        "kind": "pace-risk",
        "provider": "codex",
        "account": "default",
        "windowKind": "weekly",
        "remainingPercent": 40,
        "exhaustsAt": "2000-01-03T12:00:00.000Z",
        "errorCategory": null,
        "displayText": "⚠ weekly at risk",
        "displayDetail": "Codex · Main · Codex weekly"
      },
      "topBurn": [
        { "remote": "github.com/example/project", "percent": 25, "lastActiveAt": "2000-01-01T11:00:00.300Z" },
        { "remote": "sample-workspace", "percent": 25.5, "lastActiveAt": "2000-01-01T10:00:00.400Z" }
      ]
    }
    """

    func testReadsThePublishedQuotaPieBoundaryPath() {
        XCTAssertTrue(
            TimeQuotaCardService.quotaFileURL.path.hasSuffix(
                "/Library/Application Support/QuotaPie/quota.json"
            )
        )
    }

    func testMissingQuotaBoundaryDoesNotAdvertiseQuotaPie() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-quota-\(UUID().uuidString)/quota.json")

        XCTAssertNil(TimeQuotaCardService.loadCardState(from: missing))
    }

    func testSymlinkedQuotaBoundaryIsVisibleAsInvalid() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("linked-quota-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = root.appendingPathComponent("payload.json")
        let link = root.appendingPathComponent("quota.json")
        try Data(realShape.utf8).write(to: payload)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: payload)

        guard case .invalid = TimeQuotaCardService.loadCardState(from: link) else {
            return XCTFail("symlinked quota boundary must not be followed")
        }
    }

    func testParsesTheRealFileShape() throws {
        let snapshot = try XCTUnwrap(TimeQuotaCardService.parse(Data(realShape.utf8)))

        XCTAssertTrue(snapshot.collectionHealthy)
        XCTAssertEqual(snapshot.window?.provider, "codex")
        XCTAssertEqual(snapshot.window?.usedPercent, 60)
        XCTAssertNotNil(snapshot.window?.resetsAt)
        XCTAssertEqual(snapshot.headline?.kind, .paceRisk)
        XCTAssertEqual(snapshot.headline?.windowKind, .weekly)
        XCTAssertEqual(snapshot.headline?.remainingPercent, 40)
        XCTAssertNotNil(snapshot.headline?.exhaustsAt)
        XCTAssertNil(snapshot.headline?.errorCategory)
        XCTAssertEqual(snapshot.topBurn.map(\.remote), ["github.com/example/project", "sample-workspace"])
        XCTAssertEqual(snapshot.topBurn[1].percent, 25.5, accuracy: 0.001)
        XCTAssertEqual(
            snapshot.providerStates.map { "\($0.name)=\($0.state.rawValue)" },
            ["claude=never-attempted", "codex=recent-success"]
        )
    }

    // Fields could mean something else under a future contract. Numbers are
    // rejected, but an existing file stays visible as a health finding.
    func testUnknownSchemaVersionBecomesInvalidCardState() {
        let bumped = realShape.replacingOccurrences(of: "\"schemaVersion\": 2", with: "\"schemaVersion\": 3")

        XCTAssertNil(TimeQuotaCardService.parse(Data(bumped.utf8)))
        guard case .invalid = TimeQuotaCardService.cardState(for: Data(bumped.utf8)) else {
            return XCTFail("unknown schema must produce a visible invalid state")
        }
    }

    func testFractionalSchemaVersionIsNotRoundedDownToV2() {
        let fractional = realShape.replacingOccurrences(
            of: "\"schemaVersion\": 2",
            with: "\"schemaVersion\": 2.5"
        )

        XCTAssertNil(TimeQuotaCardService.parse(Data(fractional.utf8)))
    }

    func testUnknownHeadlineKindInvalidatesTheBoundary() {
        let unknown = realShape.replacingOccurrences(
            of: "\"kind\": \"pace-risk\"",
            with: "\"kind\": \"surprise\""
        )

        XCTAssertNil(TimeQuotaCardService.parse(Data(unknown.utf8)))
    }

    func testUnknownProviderHealthInvalidatesTheBoundary() {
        let unknown = realShape.replacingOccurrences(
            of: "\"claude\": \"never-attempted\"",
            with: "\"claude\": \"maybe\""
        )

        XCTAssertNil(TimeQuotaCardService.parse(Data(unknown.utf8)))
    }

    func testFreshnessWindowMarksADeadProducerStale() throws {
        let snapshot = try XCTUnwrap(TimeQuotaCardService.parse(Data(realShape.utf8)))
        let generatedAt = snapshot.generatedAt

        XCTAssertTrue(TimeQuotaCardService.isFresh(snapshot, now: generatedAt.addingTimeInterval(59 * 60)))
        XCTAssertFalse(TimeQuotaCardService.isFresh(snapshot, now: generatedAt.addingTimeInterval(61 * 60)))

        guard case .stale(let staleSnapshot) = TimeQuotaCardService.cardState(
            for: Data(realShape.utf8),
            now: generatedAt.addingTimeInterval(61 * 60)
        ) else {
            return XCTFail("stale boundary must remain visible without quota numbers")
        }
        XCTAssertEqual(staleSnapshot.window?.usedPercent, 60)
    }

    func testFreshBoundaryBecomesCurrentCardState() throws {
        let snapshot = try XCTUnwrap(TimeQuotaCardService.parse(Data(realShape.utf8)))

        guard case .current(let currentSnapshot) = TimeQuotaCardService.cardState(
            for: Data(realShape.utf8),
            now: snapshot.generatedAt.addingTimeInterval(10 * 60)
        ) else {
            return XCTFail("fresh v2 boundary must be current")
        }
        XCTAssertTrue(currentSnapshot.collectionHealthy)
    }

    // A producer timestamp meaningfully in the future is a clock jump, and
    // "cannot tell" must not read as maximally fresh.
    func testFutureGeneratedAtIsNotFresh() throws {
        let snapshot = try XCTUnwrap(TimeQuotaCardService.parse(Data(realShape.utf8)))

        XCTAssertFalse(TimeQuotaCardService.isFresh(snapshot, now: snapshot.generatedAt.addingTimeInterval(-120)))
        XCTAssertTrue(TimeQuotaCardService.isFresh(snapshot, now: snapshot.generatedAt.addingTimeInterval(-30)))
    }

    func testUnhealthyCollectionParsesWithTheFlagDown() throws {
        let unhealthy = realShape.replacingOccurrences(of: "\"healthy\": true", with: "\"healthy\": false")

        let snapshot = try XCTUnwrap(TimeQuotaCardService.parse(Data(unhealthy.utf8)))

        XCTAssertFalse(snapshot.collectionHealthy)
    }

    func testMalformedBurnRowsInvalidateTheBoundary() {
        let broken = realShape.replacingOccurrences(
            of: "{ \"remote\": \"sample-workspace\", \"percent\": 25.5, \"lastActiveAt\": \"2000-01-01T10:00:00.400Z\" }",
            with: "{ \"percent\": 12.0 }"
        )

        XCTAssertNil(TimeQuotaCardService.parse(Data(broken.utf8)))
    }

    func testNullWindowStillParses() throws {
        let windowless = realShape.replacingOccurrences(
            of: "\"window\": { \"provider\": \"codex\", \"usedPercent\": 60, \"resetsAt\": \"2000-01-05T12:00:00.000Z\" },",
            with: "\"window\": null,"
        )

        let snapshot = try XCTUnwrap(TimeQuotaCardService.parse(Data(windowless.utf8)))

        XCTAssertNil(snapshot.window)
        XCTAssertFalse(snapshot.topBurn.isEmpty)
    }

    func testMalformedWindowDoesNotQuietlyBecomeNoWindow() {
        let malformed = realShape.replacingOccurrences(
            of: "\"usedPercent\": 60",
            with: "\"usedPercent\": true"
        )

        XCTAssertNil(TimeQuotaCardService.parse(Data(malformed.utf8)))
    }

    func testNullUsedPercentIsAValidUnknownReading() throws {
        let unknown = realShape.replacingOccurrences(
            of: "\"usedPercent\": 60",
            with: "\"usedPercent\": null"
        )

        let snapshot = try XCTUnwrap(TimeQuotaCardService.parse(Data(unknown.utf8)))

        XCTAssertNotNil(snapshot.window)
        XCTAssertNil(snapshot.window?.usedPercent)
    }

    func testPaceRiskHeadlineOutranksLowUsedPercentage() throws {
        let lowUsed = realShape.replacingOccurrences(
            of: "\"usedPercent\": 60",
            with: "\"usedPercent\": 2"
        ).replacingOccurrences(
            of: "\"remainingPercent\": 40",
            with: "\"remainingPercent\": 98"
        )
        let snapshot = try XCTUnwrap(TimeQuotaCardService.parse(Data(lowUsed.utf8)))
        let notice = try XCTUnwrap(TimeQuotaCardPresentation.headlineNotice(for: snapshot))

        XCTAssertEqual(TimeQuotaCardPresentation.headerValue(for: .current(snapshot)), "Codex 소진 위험")
        XCTAssertEqual(notice.title, "Codex 주간 소진 위험")
        XCTAssertTrue(notice.detail.contains("98% 남음"))
        XCTAssertTrue(notice.detail.contains("소진 예상"))
    }

    func testNormalHeadlineShowsRemainingRatherThanUsedPercentage() throws {
        let normal = realShape.replacingOccurrences(
            of: "\"kind\": \"pace-risk\"",
            with: "\"kind\": \"normal\""
        )
        let snapshot = try XCTUnwrap(TimeQuotaCardService.parse(Data(normal.utf8)))

        XCTAssertNil(TimeQuotaCardPresentation.headlineNotice(for: snapshot))
        XCTAssertEqual(TimeQuotaCardPresentation.headerValue(for: .current(snapshot)), "Codex 40% 남음")
    }

    func testSetupHeadlineUsesSemanticRecoveryText() throws {
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(realShape.utf8)) as? [String: Any]
        )
        var collection = try XCTUnwrap(root["collection"] as? [String: Any])
        collection["healthy"] = false
        root["collection"] = collection
        var headline = try XCTUnwrap(root["headline"] as? [String: Any])
        headline["kind"] = "setup"
        headline["errorCategory"] = "auth-required"
        root["headline"] = headline
        let data = try JSONSerialization.data(withJSONObject: root)
        let snapshot = try XCTUnwrap(TimeQuotaCardService.parse(data))
        let notice = try XCTUnwrap(TimeQuotaCardPresentation.headlineNotice(for: snapshot))

        XCTAssertEqual(TimeQuotaCardPresentation.headerValue(for: .current(snapshot)), "설정 필요")
        XCTAssertEqual(notice.title, "Codex 설정 필요")
        XCTAssertEqual(notice.detail, "QuotaPie에서 공급자 로그인이 필요합니다.")
    }

    func testStaleBoundaryNeverCallsAnOldProviderStateRecent() throws {
        let snapshot = try XCTUnwrap(TimeQuotaCardService.parse(Data(realShape.utf8)))
        let provider = try XCTUnwrap(
            snapshot.providerStates.first { $0.state == .recentSuccess }
        )

        let status = TimeQuotaCardPresentation.providerStatus(provider, boundaryIsStale: true)

        XCTAssertEqual(status.symbol, "clock.badge.questionmark")
        XCTAssertTrue(status.title.contains("마지막 기록상 수집 성공"))
        XCTAssertFalse(status.title.contains("최근 수집 성공"))
    }
}
