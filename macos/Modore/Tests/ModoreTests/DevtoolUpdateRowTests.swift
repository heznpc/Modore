import XCTest
@testable import Modore

final class DevtoolUpdateRowTests: XCTestCase {
    func testDecodesOutdatedPackage() throws {
        let row = try XCTUnwrap(DevtoolUpdateRow(json: ["name": "ada-url", "current": "3.4.4", "latest": "4.0.0"]))

        XCTAssertEqual(row.name, "ada-url")
        XCTAssertEqual(row.current, "3.4.4")
        XCTAssertEqual(row.latest, "4.0.0")
    }

    // brew can report multiple installed versions for one formula, e.g.
    // "sqlite (3.53.2, 3.53.3) < 3.53.4" -- the comma-joined blob is kept
    // verbatim rather than parsed further, since it's genuinely accurate.
    func testKeepsMultipleInstalledVersionsVerbatim() throws {
        let row = try XCTUnwrap(DevtoolUpdateRow(json: ["name": "sqlite", "current": "3.53.2, 3.53.3", "latest": "3.53.4"]))

        XCTAssertEqual(row.current, "3.53.2, 3.53.3")
    }

    // scanner_helper.jxa.js only ever emits rows with all three fields
    // populated -- a row missing one is malformed input and must not
    // silently render with a blank name or version.
    func testRejectsRowsMissingRequiredFields() {
        XCTAssertNil(DevtoolUpdateRow(json: ["current": "1.0", "latest": "2.0"]))
        XCTAssertNil(DevtoolUpdateRow(json: ["name": "foo", "latest": "2.0"]))
        XCTAssertNil(DevtoolUpdateRow(json: ["name": "foo", "current": "1.0"]))
        XCTAssertNil(DevtoolUpdateRow(json: [:]))
    }

    // brew appends " [pinned at X]" for a pinned formula or cask. The row is
    // kept (dropping it made the collector's count disagree with the list)
    // and flagged, since "an update exists" reads differently for a package
    // the owner deliberately held back.
    func testDecodesAPinnedPackage() throws {
        let row = try XCTUnwrap(DevtoolUpdateRow(json: [
            "name": "node", "current": "18.0.0", "latest": "20.0.0", "pinned": true,
        ]))

        XCTAssertTrue(row.pinned)
        XCTAssertEqual(row.latest, "20.0.0")
    }

    func testDefaultsToNotPinnedWhenTheFieldIsAbsent() throws {
        let row = try XCTUnwrap(DevtoolUpdateRow(json: [
            "name": "ada-url", "current": "3.4.4", "latest": "4.0.0",
        ]))

        XCTAssertFalse(row.pinned)
    }
}
