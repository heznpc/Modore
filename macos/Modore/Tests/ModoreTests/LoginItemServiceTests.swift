import XCTest
@testable import Modore

final class LoginItemServiceTests: XCTestCase {
    // MARK: - mapPreviewOutcome

    func testPreviewReadyReturnsTheApprovalToken() {
        let outcome = LoginItemService.mapPreviewOutcome(
            ["status": "ready", "name": "Bar", "approvalToken": String(repeating: "a", count: 64)],
            requestedName: "Bar"
        )

        XCTAssertEqual(outcome, .ready(name: "Bar", approvalToken: String(repeating: "a", count: 64)))
    }

    func testPreviewReadyWithoutAUsableTokenIsAFailureNotASilentReady() {
        // A malformed or missing approvalToken must never be treated as if
        // the preview succeeded -- there would be nothing to execute with.
        let outcome = LoginItemService.mapPreviewOutcome(
            ["status": "ready", "name": "Bar", "approvalToken": "too-short"],
            requestedName: "Bar"
        )

        guard case .failure = outcome else {
            return XCTFail("expected .failure, got \(outcome)")
        }
    }

    func testPreviewNotFoundUsesTheReportedName() {
        let outcome = LoginItemService.mapPreviewOutcome(
            ["status": "not_found", "name": "Missing"],
            requestedName: "Missing"
        )

        XCTAssertEqual(outcome, .notFound(name: "Missing"))
    }

    func testPreviewFallsBackToTheRequestedNameWhenTheProtocolOmitsIt() {
        let outcome = LoginItemService.mapPreviewOutcome(["status": "not_found"], requestedName: "Bar")

        XCTAssertEqual(outcome, .notFound(name: "Bar"))
    }

    func testPreviewUnknownStatusIsAFailure() {
        let outcome = LoginItemService.mapPreviewOutcome(["status": "blocked", "name": "Bar"], requestedName: "Bar")

        guard case .failure = outcome else {
            return XCTFail("expected .failure, got \(outcome)")
        }
    }

    // MARK: - mapExecuteOutcome

    func testExecuteOkReturnsTheReportedName() {
        let outcome = LoginItemService.mapExecuteOutcome(["status": "ok", "name": "Bar"], requestedName: "Bar")

        XCTAssertEqual(outcome, .ok(name: "Bar"))
    }

    func testExecuteAlreadyGoneIsDistinctFromOk() {
        // already_gone means the desired end state already held before this
        // call did anything -- it must not collapse into the same case as a
        // real removal, since callers may want to log/announce differently.
        let outcome = LoginItemService.mapExecuteOutcome(["status": "already_gone", "name": "Bar"], requestedName: "Bar")

        XCTAssertEqual(outcome, .alreadyGone(name: "Bar"))
        XCTAssertNotEqual(outcome, .ok(name: "Bar"))
    }

    func testExecuteUnknownStatusIsAFailureCarryingTheName() {
        let outcome = LoginItemService.mapExecuteOutcome(["status": "expired", "name": "Bar"], requestedName: "Bar")

        guard case .failure(_, let name) = outcome else {
            return XCTFail("expected .failure, got \(outcome)")
        }
        XCTAssertEqual(name, "Bar")
    }
}
