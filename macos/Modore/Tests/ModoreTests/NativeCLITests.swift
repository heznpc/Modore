import Foundation
import XCTest
@testable import Modore

final class NativeCLITests: XCTestCase {
    private func parse(_ args: [String]) throws -> (String, [String: Any]) { try NativeCLI.parse(["Modore", NativeCLI.argument] + args) }
    func testCIUsesTheSameStructuredRequestAsTheApp() throws {
        let (operation, request) = try parse(["ci", "refresh", "--repo", "owner/one", "--repo", "owner/two", "--project", "/tmp/example", "--discover"])
        XCTAssertEqual(operation, "ci"); XCTAssertEqual(request["action"] as? String, "refresh")
        XCTAssertEqual(request["repos"] as? [String], ["owner/one", "owner/two"]); XCTAssertEqual(request["discover"] as? Bool, true)
        XCTAssertThrowsError(try parse(["ci", "refresh", "--request-file", "/tmp/request"]))
    }
    func testBackupsRequireSensitiveAcknowledgementAndKeepPathsAsData() throws {
        XCTAssertThrowsError(try parse(["sessions", "backup", "/tmp/source", "--out", "/tmp/new.zip"]))
        let (operation, request) = try parse(["sessions", "backup", "/tmp/한글 source", "--out", "/tmp/new.zip", "--include-sensitive"])
        XCTAssertEqual(operation, "session-backup")
        XCTAssertEqual(request["arguments"] as? [String], ["backup", "/tmp/한글 source", "--out", "/tmp/new.zip", "--include-sensitive"])
        for flag in ["--home", "--request-file", "--approve"] { XCTAssertThrowsError(try parse(["sessions", "backup-verify", "/tmp/archive.zip", flag, "/tmp/other"])) }
        XCTAssertThrowsError(try parse(["sessions", "backup-verify", "/tmp/archive.zip", "--out", "/tmp/output"]))
    }
    func testSkillMutationsRequireASelectionAndFingerprint() throws {
        XCTAssertThrowsError(try parse(["skills", "disable", "--id", "example"]))
        let (_, request) = try parse(["skills", "disable", "--id", "example", "--fingerprint", "digest"])
        XCTAssertEqual(request["id"] as? String, "example"); XCTAssertEqual(request["fingerprint"] as? String, "digest")
        XCTAssertThrowsError(try parse(["skills", "compare", "--id", "only-one"]))
    }
    func testSimulatorDeletionAndUnknownOptionsAreRejected() throws {
        XCTAssertThrowsError(try parse(["resources", "delete-duplicate", "--id", UUID().uuidString]))
        XCTAssertThrowsError(try parse(["resources", "status", "--root", "/tmp/other"]))
        XCTAssertThrowsError(try parse(["ci", "status", "--discover", "--discover"]))
    }
}
