import Foundation
@preconcurrency import UserNotifications

enum PressureNotification {
    static let category = "modore-storage-pressure"
    static let healthCategory = "modore-resource-pressure"
    static let recoveryAction = "modore-open-recovery"
    static let healthAction = "modore-open-health"
    static let reviewAction = "modore-review-resource"

    static func register(on center: UNUserNotificationCenter) {
        center.setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [
                UNNotificationAction(identifier: recoveryAction, title: L10n.text("정리 후보 검토"), options: .foreground),
                UNNotificationAction(identifier: healthAction, title: L10n.text("RAM 사용량 검토"), options: .foreground),
            ], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: healthCategory, actions: [
                UNNotificationAction(identifier: reviewAction, title: L10n.text("사용량·조치 보기"), options: .foreground),
            ], intentIdentifiers: [], options: [])
        ])
    }

    static func retireLegacyNotices(on center: UNUserNotificationCenter, defaults: UserDefaults = .standard) {
        let key = "actionableResourceNoticeVersion"
        guard defaults.integer(forKey: key) < 1 else { return }
        // Historical measurements remain in their journals. Old banners have
        // misleading resource attribution and no direct review destination.
        center.removeDeliveredNotifications(withIdentifiers: [category, "modore-health", "modore-automatic-cache-recovery"])
        defaults.set(1, forKey: key)
    }

    static func destination(action: String, route: String?) -> URL? {
        if action == UNNotificationDefaultActionIdentifier && route == "ci" {
            return URL(string: "modore://work/ci")
        }
        if action == healthAction { return URL(string: "modore://health/memory") }
        if action == UNNotificationDefaultActionIdentifier && route == "storage-result" {
            return URL(string: "modore://storage/result")
        }
        if action == recoveryAction || (action == UNNotificationDefaultActionIdentifier && route == "storage") {
            return URL(string: "modore://storage/recovery")
        }
        if action == UNNotificationDefaultActionIdentifier || action == reviewAction {
            switch route {
            case "health": return URL(string: "modore://health")
            case "memory": return URL(string: "modore://health/memory")
            case "cpu": return URL(string: "modore://health/cpu")
            default: return nil
            }
        }
        return nil
    }
}
