import XCTest
import UserNotifications
@testable import Modore

final class PressureNotificationTests: XCTestCase {
    func testStorageClickOpensReviewAndActionsNeverExecuteCleanup() {
        XCTAssertEqual(PressureNotification.destination(action: UNNotificationDefaultActionIdentifier, route: "storage"),
                       URL(string: "modore://storage/recovery"))
        XCTAssertEqual(PressureNotification.destination(action: PressureNotification.recoveryAction, route: "storage"),
                       URL(string: "modore://storage/recovery"))
        XCTAssertEqual(PressureNotification.destination(action: PressureNotification.healthAction, route: "storage"),
                       URL(string: "modore://health/memory"))
        XCTAssertNil(PressureNotification.destination(action: UNNotificationDismissActionIdentifier, route: "storage"))
        XCTAssertNil(PressureNotification.destination(action: "execute-cleanup", route: "storage"))
    }

    func testResourceNotificationsOpenRelevantReviewWithoutMutation() throws {
        for (route, url, expected) in [
            ("memory", "modore://health/memory", ModoreRoute.healthResources(.memory)),
            ("cpu", "modore://health/cpu", ModoreRoute.healthResources(.cpu)),
            ("storage-result", "modore://storage/result", ModoreRoute.storageRecoveryResult),
        ] {
            let destination = try XCTUnwrap(PressureNotification.destination(action: UNNotificationDefaultActionIdentifier, route: route))
            XCTAssertEqual(destination.absoluteString, url)
            XCTAssertEqual(ModoreRoute(url: destination), expected)
            XCTAssertFalse(expected.shouldStartStorageScan(hasStorageData: false, isBusy: false))
            XCTAssertNil(PressureNotification.destination(action: UNNotificationDismissActionIdentifier, route: route))
            XCTAssertNil(PressureNotification.destination(action: "execute-cleanup", route: route))
        }
        XCTAssertEqual(PressureNotification.destination(action: PressureNotification.reviewAction, route: "cpu"), URL(string: "modore://health/cpu"))
        XCTAssertNil(PressureNotification.destination(action: PressureNotification.reviewAction, route: "untrusted"))
    }
}
