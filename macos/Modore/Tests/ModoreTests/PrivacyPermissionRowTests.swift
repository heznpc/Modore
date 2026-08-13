import XCTest
@testable import Modore

final class PrivacyPermissionRowTests: XCTestCase {
    func testDecodesCameraGrant() throws {
        let row = try XCTUnwrap(PrivacyPermissionRow(json: ["kind": "camera", "client": "com.apple.FaceTime"]))

        XCTAssertEqual(row.client, "com.apple.FaceTime")
        XCTAssertTrue(row.isCamera)
    }

    func testDecodesMicrophoneGrant() throws {
        let row = try XCTUnwrap(PrivacyPermissionRow(json: ["kind": "microphone", "client": "com.apple.FaceTime"]))

        XCTAssertFalse(row.isCamera)
    }

    // scanner_helper.jxa.js only ever emits "camera"/"microphone"/nothing --
    // a row with neither field populated is malformed input, not a third
    // valid kind, and must not silently render as a blank list entry.
    func testRejectsRowsMissingRequiredFields() {
        XCTAssertNil(PrivacyPermissionRow(json: ["kind": "camera"]))
        XCTAssertNil(PrivacyPermissionRow(json: ["client": "com.apple.FaceTime"]))
        XCTAssertNil(PrivacyPermissionRow(json: [:]))
    }
}
