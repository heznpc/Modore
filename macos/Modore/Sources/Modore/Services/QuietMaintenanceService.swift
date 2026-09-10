import AppKit
import CoreGraphics
import Foundation

@MainActor
enum LocalUserPresence {
    static var displayAsleep = false
    static var allowsNotification: Bool {
        guard !displayAsleep, CGDisplayIsAsleep(CGMainDisplayID()) == 0, let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool != true
            && session[kCGSessionOnConsoleKey as String] as? Bool == true
    }
}

@MainActor
final class QuietMaintenanceService: ObservableObject {
    private var task: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    func start(model: ScanModel) {
        guard task == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName:NSWorkspace.screensDidSleepNotification,object:nil,queue:.main) { _ in
            Task { @MainActor in LocalUserPresence.displayAsleep = true }
        })
        observers.append(center.addObserver(forName:NSWorkspace.screensDidWakeNotification,object:nil,queue:.main) { _ in
            Task { @MainActor in LocalUserPresence.displayAsleep = false }
        })
        task = Task { [weak model] in
            while !Task.isCancelled {
                if let model, !model.cleanupInFlight, !model.applicationTerminationStarted {
                    // The persisted policy is opt-in. No notifications, wake assertions,
                    // new device deletion authority, or approvals shared with other apps.
                    model.cleanupInFlight = true
                    model.beginDestructiveCleanupTransaction()
                    do { _ = try await EnvironmentRetirementService.invoke(root:model.projectRoot,request:["action":"tick"]) }
                    catch { model.appendLog("예약 환경 정리 확인 실패: \(error.localizedDescription)") }
                    model.cleanupInFlight = false
                    model.finishDestructiveCleanupTransaction()
                }
                do { try await Task.sleep(nanoseconds:60_000_000_000) } catch { return }
            }
        }
    }
}
