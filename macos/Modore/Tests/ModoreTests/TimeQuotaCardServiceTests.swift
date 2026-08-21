import XCTest
@testable import Modore

final class TimeQuotaCardServiceTests: XCTestCase {
    /// Synthetic quota boundary fixture covers nullable errors, fractional timestamps, mixed numeric percentages, and a non-Git workspace name.
    private let realShape = """
    {
      "schemaVersion": 1,
      "generatedAt": "2000-01-01T12:00:00.100Z",
      "collection": {
        "lastSampleAt": "2000-01-01T12:00:01.200Z",
        "healthy": true,
        "providers": { "codex": "recent-success", "claude": "never-attempted" }
      },
      "window": { "provider": "codex", "usedPercent": 60, "resetsAt": "2000-01-05T12:00:00.000Z" },
      "topBurn": [
        { "remote": "github.com/example/project", "percent": 25, "lastActiveAt": "2000-01-01T11:00:00.300Z" },
        { "remote": "sample-workspace", "percent": 25.5, "lastActiveAt": "2000-01-01T10:00:00.400Z" }
      ]
    }
    """

    func testParsesTheRealFileShape() throws {
        let snapshot = try XCTUnwrap(TimeQuotaCardService.parse(Data(realShape.utf8)))

        XCTAssertTrue(snapshot.collectionHealthy)
        XCTAssertEqual(snapshot.window?.provider, "codex")
        XCTAssertEqual(snapshot.window?.usedPercent, 60)
        XCTAssertNotNil(snapshot.window?.resetsAt)
        XCTAssertEqual(snapshot.topBurn.map(\.remote), ["github.com/example/project", "sample-workspace"])
        XCTAssertEqual(snapshot.topBurn[1].percent, 25.5, accuracy: 0.001)
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
            of: "{ \"remote\": \"sample-workspace\", \"percent\": 25.5, \"lastActiveAt\": \"2000-01-01T10:00:00.400Z\" }",
            with: "{ \"percent\": 12.0 }"
        )

        let snapshot = try XCTUnwrap(TimeQuotaCardService.parse(Data(broken.utf8)))

        XCTAssertEqual(snapshot.topBurn.map(\.remote), ["github.com/example/project"])
    }

    func testMissingWindowStillParses() throws {
        let windowless = realShape.replacingOccurrences(
            of: "\"window\": { \"provider\": \"codex\", \"usedPercent\": 60, \"resetsAt\": \"2000-01-05T12:00:00.000Z\" },",
            with: ""
        )

        let snapshot = try XCTUnwrap(TimeQuotaCardService.parse(Data(windowless.utf8)))

        XCTAssertNil(snapshot.window)
        XCTAssertFalse(snapshot.topBurn.isEmpty)
    }
}
