import AppKit
import Foundation

/// The minute watcher owns launching; the persisted opt-in and common recovery
/// engine own authorization, cooldowns, evidence, receipts and notifications.
enum BackgroundCacheRecovery {
    static let launchArgument = "--automatic-storage-recovery"

    @MainActor
    static func runAndExit() -> Never {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard UserDefaults.standard.bool(forKey: "automaticSafeCacheRecovery") else { exit(0) }
        Task { @MainActor in
            let recovery = AutomaticCacheRecovery()
            guard recovery.isDue else { exit(0) }
            let model = ScanModel(automaticallyScansStaleResults: false)
            await recovery.runIfNeeded(model: model, snapshot: nil)
            exit(0)
        }
        // Keep the main actor responsive while the existing async engine runs.
        // A semaphore here would deadlock every main-actor continuation.
        RunLoop.main.run()
        exit(1)
    }
}
