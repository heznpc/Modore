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
                       URL(string: "modore://health"))
        XCTAssertNil(PressureNotification.destination(action: UNNotificationDismissActionIdentifier, route: "storage"))
        XCTAssertNil(PressureNotification.destination(action: "execute-cleanup", route: "storage"))
    }
}
