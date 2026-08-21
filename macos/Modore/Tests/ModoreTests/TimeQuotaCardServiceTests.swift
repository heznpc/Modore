import XCTest
@testable import Modore

final class TimeQuotaCardServiceTests: XCTestCase {
    /// Byte-shape of the real quota.json observed on this machine (values
    /// included), not an idealized fixture -- fractional-second ISO8601,
    /// integer and fractional percents, a bare non-git "remote" name.
    private let realShape = """
    {
      "schemaVersion": 1,
      "generatedAt": "2026-08-16T16:48:11.980Z",
      "collection": {
        "lastSampleAt": "2026-08-16T16:48:13.130Z",
        "healthy": true,
        "providers": { "codex": "recent-success", "claude": "never-attempted" }
      },
      "window": { "provider": "codex", "usedPercent": 66, "resetsAt": "2026-08-20T05:33:04.000Z" },
      "topBurn": [
        { "remote": "github.com/heznpc/modore", "percent": 29, "lastActiveAt": "2026-08-16T16:08:48.446Z" },
        { "remote": "ren", "percent": 28.8, "lastActiveAt": "2026-08-16T16:01:48.213Z" }
      ]
    }
    """

    func testParsesTheRealFileShape() throws {
        let snapshot = try XCTUnwrap(TimeQuotaCardService.parse(Data(realShape.utf8)))

        XCTAssertTrue(snapshot.collectionHealthy)
        XCTAssertEqual(snapshot.window?.provider, "codex")
        XCTAssertEqual(snapshot.window?.usedPercent, 66)
        XCTAssertNotNil(snapshot.window?.resetsAt)
        XCTAssertEqual(snapshot.topBurn.map(\.remote), ["github.com/heznpc/modore", "ren"])
        XCTAssertEqual(snapshot.topBurn[1].percent, 28.8, accuracy: 0.001)
        XCTAssertEqual(
            snapshot.providerStates.map { "\($0.name)=\($0.state)" },
            ["claude=never-attempted", "codex=recent-success"]
        )
    }

    // Fields could mean something else under a future contract; the agreed
    // failure mode is a hidden card, not a guessed rendering.
    func testRejectsAnUnknownSchemaVersion() {
        let bumped = realShape.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 2")

        XCTAssertNil(TimeQuotaCardService.parse(Data(bumped.utf8)))
    }

    func testFreshnessWindowHidesADeadProducer() throws {
        let snapshot = try XCTUnwrap(TimeQuotaCardService.parse(Data(realShape.utf8)))
        let generatedAt = snapshot.generatedAt

        XCTAssertTrue(TimeQuotaCardService.isFresh(snapshot, now: generatedAt.addingTimeInterval(59 * 60)))
        XCTAssertFalse(TimeQuotaCardService.isFresh(snapshot, now: generatedAt.addingTimeInterval(61 * 60)))
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

    func testMalformedBurnRowsAreDroppedNotZeroFilled() throws {
        let broken = realShape.replacingOccurrences(
            of: "{ \"remote\": \"ren\", \"percent\": 28.8, \"lastActiveAt\": \"2026-08-16T16:01:48.213Z\" }",
            with: "{ \"percent\": 12.0 }"
        )

        let snapshot = try XCTUnwrap(TimeQuotaCardService.parse(Data(broken.utf8)))

        XCTAssertEqual(snapshot.topBurn.map(\.remote), ["github.com/heznpc/modore"])
    }

    func testMissingWindowStillParses() throws {
        let windowless = realShape.replacingOccurrences(
            of: "\"window\": { \"provider\": \"codex\", \"usedPercent\": 66, \"resetsAt\": \"2026-08-20T05:33:04.000Z\" },",
            with: ""
        )

        let snapshot = try XCTUnwrap(TimeQuotaCardService.parse(Data(windowless.utf8)))

        XCTAssertNil(snapshot.window)
        XCTAssertFalse(snapshot.topBurn.isEmpty)
    }
}
