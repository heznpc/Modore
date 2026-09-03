import AppKit
import Foundation
@preconcurrency import UserNotifications

struct BackgroundNotificationRequest: Equatable, Sendable {
    let message: String
    let acknowledgementURL: URL
    let nonce: String
}

/// The scheduled hourly watch launches the app itself with `--post-storage-notice
/// <message>` so the resulting banner is attributed to Modore's own identity
/// rather than com.apple.ScriptEditor2 — the only identity `osascript display
/// notification` can ever use, an Apple-binary entitlement this app cannot
/// acquire. The watcher deliberately stays quiet when this path is unavailable;
/// presenting a Script Editor alert as though it came from Modore is misleading.
///
/// Authorization is requested only from a clear foreground moment — when the
/// owner turns the watch on in Settings, see `ScanModel.setStorageWatchEnabled`
/// — never from here. A silent background launch that popped a permission
/// dialog would be its own small incident, so if authorization was never
/// granted (denied, or an install that predates priming), this exits quietly
/// instead of asking.
enum BackgroundNotifier {
    static let launchArgument = "--post-storage-notice"
    static let acknowledgementArgument = "--storage-notice-ack"
    static let nonceArgument = "--storage-notice-nonce"

    /// Pure and independent of any notification API so it is fully testable
    /// without a display or a granted authorization: the message immediately
    /// following `--post-storage-notice`, or nil for a normal launch.
    static func pendingRequest(in arguments: [String]) -> BackgroundNotificationRequest? {
        guard let message = singleValue(after: launchArgument, in: arguments),
              !message.isEmpty,
              message.utf8.count <= 2_048,
              !message.utf8.contains(0),
              let acknowledgementPath = singleValue(
                after: acknowledgementArgument,
                in: arguments
              ),
              acknowledgementPath.hasPrefix("/"),
              acknowledgementPath.utf8.count <= 16_384,
              !acknowledgementPath.utf8.contains(0),
              let nonce = singleValue(after: nonceArgument, in: arguments),
              let parsedNonce = UUID(uuidString: nonce),
              parsedNonce.uuidString.caseInsensitiveCompare(nonce) == .orderedSame else {
            return nil
        }
        return BackgroundNotificationRequest(
            message: message,
            acknowledgementURL: URL(fileURLWithPath: acknowledgementPath),
            nonce: nonce
        )
    }

    private static func singleValue(after flag: String, in arguments: [String]) -> String? {
        let matches = arguments.indices.filter { arguments[$0] == flag }
        guard matches.count == 1,
              let index = matches.first,
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    @discardableResult
    static func acknowledgeAcceptedRequest(
        _ request: BackgroundNotificationRequest,
        error: Error?,
        stateDirectory: URL = StorageHistoryStore.stateDirectory
    ) -> Bool {
        guard error == nil else { return false }
        let expectedDirectory = stateDirectory.standardizedFileURL
        let acknowledgementURL = request.acknowledgementURL.standardizedFileURL
        guard acknowledgementURL.deletingLastPathComponent() == expectedDirectory,
              acknowledgementURL.lastPathComponent.hasPrefix(".storage-watch-ack."),
              acknowledgementURL.lastPathComponent.utf8.count <= 128,
              let parentIdentity = FilesystemIdentity.directory(at: expectedDirectory) else {
            return false
        }
        do {
            try SecureLocalFileIO.atomicWrite(
                Data(request.nonce.utf8),
                to: acknowledgementURL,
                permissions: 0o600,
                expectedParentIdentity: parentIdentity
            )
            return true
        } catch {
            return false
        }
    }

    /// Posts under this app's own identity and terminates. Never returns.
    /// Bounded by a hard timeout rather than an unconditional wait: the
    /// authorization-check and post completion handlers are not guaranteed to
    /// land on a particular queue, so this must not risk hanging the launched
    /// process if one never fires. Worst case is a few seconds of invisible
    /// (`open -g -j`, never activated) background time before a clean exit.
    @MainActor
    static func postAndExit(request backgroundRequest: BackgroundNotificationRequest) -> Never {
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
            content.body = backgroundRequest.message
            let request = UNNotificationRequest(
                identifier: "storage-watch-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request) { error in
                _ = acknowledgeAcceptedRequest(backgroundRequest, error: error)
                semaphore.signal()
            }
        }
        _ = semaphore.wait(timeout: .now() + 3)
        exit(0)
    }
}
