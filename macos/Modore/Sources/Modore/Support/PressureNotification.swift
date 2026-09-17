import Foundation
@preconcurrency import UserNotifications

enum PressureNotification {
    static let category = "modore-storage-pressure"
    static let recoveryAction = "modore-open-recovery"
    static let healthAction = "modore-open-health"

    static func register(on center: UNUserNotificationCenter) {
        center.setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [
                UNNotificationAction(identifier: recoveryAction, title: L10n.text("공간 확보"), options: .foreground),
                UNNotificationAction(identifier: healthAction, title: L10n.text("실행 중인 앱 확인"), options: .foreground),
            ], intentIdentifiers: [], options: [])
        ])
    }

    static func destination(action: String, route: String?) -> URL? {
        if action == UNNotificationDefaultActionIdentifier && route == "ci" {
            return URL(string: "modore://work/ci")
        }
        if action == healthAction { return URL(string: "modore://health") }
        if action == recoveryAction || (action == UNNotificationDefaultActionIdentifier && route == "storage") {
            return URL(string: "modore://storage/recovery")
        }
        if action == UNNotificationDefaultActionIdentifier && route == "health" {
            return URL(string: "modore://health")
        }
        return nil
    }
}
