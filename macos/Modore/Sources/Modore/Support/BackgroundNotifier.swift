import AppKit
import Foundation
@preconcurrency import UserNotifications

/// The scheduled hourly watch launches the app itself with `--post-storage-notice
/// <message>` so the resulting banner is attributed to Modore's own identity
/// rather than com.apple.ScriptEditor2 — the only identity `osascript display
/// notification` can ever use, an Apple-binary entitlement this app cannot
/// acquire. `scripts/storage_watch.sh` still falls back to osascript whenever
/// this path is unavailable, so this is additive and never a regression.
///
/// Authorization is requested only from a clear foreground moment — when the
/// owner turns the watch on in Settings, see `ScanModel.setStorageWatchEnabled`
/// — never from here. A silent background launch that popped a permission
/// dialog would be its own small incident, so if authorization was never
/// granted (denied, or an install that predates priming), this exits quietly
/// instead of asking.
enum BackgroundNotifier {
    static let launchArgument = "--post-storage-notice"

    /// Pure and independent of any notification API so it is fully testable
    /// without a display or a granted authorization: the message immediately
    /// following `--post-storage-notice`, or nil for a normal launch.
    static func pendingMessage(in arguments: [String]) -> String? {
        guard let flagIndex = arguments.firstIndex(of: launchArgument),
              arguments.indices.contains(flagIndex + 1) else { return nil }
        return arguments[flagIndex + 1]
    }

    /// Posts under this app's own identity and terminates. Never returns.
    /// Bounded by a hard timeout rather than an unconditional wait: the
    /// authorization-check and post completion handlers are not guaranteed to
    /// land on a particular queue, so this must not risk hanging the launched
    /// process if one never fires. Worst case is a few seconds of invisible
    /// (`open -g -j`, never activated) background time before a clean exit.
    @MainActor
    static func postAndExit(message: String) -> Never {
        // `open -g -j` already skips activation; this additionally keeps a Dock
        // icon from ever appearing for what should be an invisible launch.
        NSApplication.shared.setActivationPolicy(.prohibited)

        let center = UNUserNotificationCenter.current()
        let semaphore = DispatchSemaphore(value: 0)
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                semaphore.signal()
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Modore"
            content.body = message
            let request = UNNotificationRequest(
                identifier: "storage-watch-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request) { _ in semaphore.signal() }
        }
        _ = semaphore.wait(timeout: .now() + 3)
        exit(0)
    }
}
