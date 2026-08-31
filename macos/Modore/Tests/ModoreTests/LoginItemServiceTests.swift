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

@MainActor
final class LoginItemActionLifecycleTests: XCTestCase {
    private func readyModel() async -> ScanModel {
        let model = ScanModel(automaticallyScansStaleResults: false)
        let tasks = model.cancelTrackedApplicationTasks()
        for task in tasks { await task.value }
        return model
    }

    func testSuccessfulExecuteSchedulesARescan() async {
        let model = await readyModel()
        model.pendingLoginItemRemoval = PendingLoginItemRemoval(
            name: "Bar",
            approvalToken: String(repeating: "a", count: 64)
        )
        var rescans = 0

        model.confirmLoginItemRemoval(
            using: { _ in .ok(name: "Bar") },
            rescan: { rescans += 1 }
        )
        let task = model.loginItemActionTask
        await task?.value

        XCTAssertEqual(rescans, 1)
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.loginItemActionTask)
    }

    func testFailedExecuteStillSchedulesARescanAndKeepsFailure() async {
        let model = await readyModel()
        model.pendingLoginItemRemoval = PendingLoginItemRemoval(
            name: "Bar",
            approvalToken: String(repeating: "a", count: 64)
        )
        var rescans = 0

        model.confirmLoginItemRemoval(
            using: { _ in .failure("status line lost", name: "Bar") },
            rescan: {
                // Mirrors runScan's start contract: a new scan clears the
                // generic error before starting its owned task.
                model.errorMessage = nil
                rescans += 1
            }
        )
        let task = model.loginItemActionTask
        await task?.value

        XCTAssertEqual(rescans, 1)
        XCTAssertEqual(model.errorMessage, "status line lost")
        XCTAssertNil(model.loginItemActionTask)
    }
}
