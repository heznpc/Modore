import Darwin
import XCTest
@testable import Modore

final class AppInstanceCoordinatorTests: XCTestCase {
    private let bundleID = "me.heznpc.modore"

    func testCurrentProcessAndOtherBundleIdentifiersAreIgnored() {
        let decision = AppInstanceCoordinator.decide(
            bundleIdentifier: bundleID,
            currentPID: 20,
            candidates: [
                .init(processIdentifier: 20, bundleIdentifier: bundleID, launchedAt: 1, isRegularApplication: true),
                .init(processIdentifier: 10, bundleIdentifier: "example.other", launchedAt: 0, isRegularApplication: true),
            ],
            lockState: .acquired
        )

        XCTAssertEqual(decision, .continueRunning)
    }

    func testOldestMatchingPeerWinsDeterministically() {
        let decision = AppInstanceCoordinator.decide(
            bundleIdentifier: bundleID,
            currentPID: 99,
            candidates: [
                .init(processIdentifier: 42, bundleIdentifier: bundleID, launchedAt: 20, isRegularApplication: true),
                .init(processIdentifier: 8, bundleIdentifier: bundleID, launchedAt: 10, isRegularApplication: true),
                .init(processIdentifier: 7, bundleIdentifier: bundleID, launchedAt: 10, isRegularApplication: true),
            ],
            lockState: .busy
        )

        XCTAssertEqual(decision, .activateExistingAndExit(7))
    }

    func testBusyLockExitsEvenBeforeLaunchServicesPublishesWinner() {
        XCTAssertEqual(
            AppInstanceCoordinator.decide(
                bundleIdentifier: bundleID,
                currentPID: 99,
                candidates: [],
                lockState: .busy
            ),
            .activateExistingAndExit(nil)
        )
    }

    func testLockElectionLeavesExactlyOneOfTwoSimultaneousLaunchesRunning() {
        let candidates = [
            AppInstanceCoordinator.Candidate(
                processIdentifier: 1,
                bundleIdentifier: bundleID,
                launchedAt: 10,
                isRegularApplication: true
            ),
            AppInstanceCoordinator.Candidate(
                processIdentifier: 2,
                bundleIdentifier: bundleID,
                launchedAt: 10,
                isRegularApplication: true
            ),
        ]
        let winner = AppInstanceCoordinator.decide(
            bundleIdentifier: bundleID,
            currentPID: 1,
            candidates: candidates,
            lockState: .acquired
        )
        let loser = AppInstanceCoordinator.decide(
            bundleIdentifier: bundleID,
            currentPID: 2,
            candidates: candidates,
            lockState: .busy
        )

        XCTAssertEqual(winner, .continueRunning)
        XCTAssertEqual(loser, .activateExistingAndExit(1))
    }

    func testNotificationOnlyPeerIsNeverActivatedAsTheMainUI() {
        let decision = AppInstanceCoordinator.decide(
            bundleIdentifier: bundleID,
            currentPID: 2,
            candidates: [
                .init(
                    processIdentifier: 1,
                    bundleIdentifier: bundleID,
                    launchedAt: 10,
                    isRegularApplication: false
                ),
            ],
            lockState: .busy
        )

        XCTAssertEqual(decision, .activateExistingAndExit(nil))
    }

    func testNonBundleExecutableDoesNotJoinGlobalSingleton() {
        XCTAssertEqual(
            AppInstanceCoordinator.decide(
                bundleIdentifier: nil,
                currentPID: 99,
                candidates: [],
                lockState: .busy
            ),
            .continueRunning
        )
    }

    func testUnavailableLockFailsClosedWithoutAnExistingUI() {
        XCTAssertEqual(
            AppInstanceCoordinator.decide(
                bundleIdentifier: bundleID,
                currentPID: 99,
                candidates: [],
                lockState: .unavailable
            ),
            .cannotCoordinate
        )
    }

    func testLeaseIsExclusiveAndReleasesWithOwner() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("modore-instance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var firstLease: AppInstanceCoordinator.Lease?
        switch AppInstanceCoordinator.acquireLease(at: root) {
        case .acquired(let lease): firstLease = lease
        default: return XCTFail("first process should acquire the lease")
        }
        XCTAssertNotNil(firstLease)
        if case .busy = AppInstanceCoordinator.acquireLease(at: root) {
            // Expected while the first descriptor remains alive.
        } else {
            XCTFail("second process must see a busy lease")
        }

        firstLease = nil
        if case .acquired = AppInstanceCoordinator.acquireLease(at: root) {
            // Normal termination releases the advisory lock.
        } else {
            XCTFail("lease should be acquirable after its owner exits")
        }
    }

    func testSymlinkedSupportDirectoryCannotHostTheLease() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("modore-instance-symlink-\(UUID().uuidString)", isDirectory: true)
        let real = root.appendingPathComponent("real", isDirectory: true)
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: root) }

        if case .unavailable = AppInstanceCoordinator.acquireLease(at: linked) {
            return
        }
        XCTFail("a symlinked coordination directory must be rejected")
    }

    func testSymlinkedIntermediateDirectoryCannotRedirectTheLease() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("modore-instance-parent-link-\(UUID().uuidString)", isDirectory: true)
        let real = root.appendingPathComponent("real", isDirectory: true)
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: root) }

        if case .unavailable = AppInstanceCoordinator.acquireLease(
            at: linked.appendingPathComponent("Modore", isDirectory: true)
        ) {
            return
        }
        XCTFail("a symlink in the coordination path must be rejected")
    }
}
