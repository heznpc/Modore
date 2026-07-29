import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Posts VoiceOver announcements for terminal outcomes only (scan, cleanup,
/// protection, watch, and approved browser-stop state changes). Failure paths
/// already surface an error alert, so they deliberately do not announce here.
///
/// All production announcements route through `announce(_:)`; `handler` is
/// swapped in tests to assert exactly which terminal events speak.
@MainActor
enum AccessibilityAnnouncer {
    static var handler: @MainActor (String) -> Void = post

    static func announce(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        handler(trimmed)
    }

    private static func post(_ message: String) {
        #if canImport(AppKit)
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
        #endif
    }
}
