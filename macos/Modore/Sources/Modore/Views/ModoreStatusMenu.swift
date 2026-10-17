import AppKit
import SwiftUI

/// The menu is a glance and an entry point; investigations remain in the
/// main window so approvals and recovery are never squeezed into a popover.
struct ModoreStatusMenu: View {
    @EnvironmentObject private var monitor: CPUWatchService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            if let snapshot = monitor.snapshot {
                Text(L10n.format("실제 여유 %@", HealthSnapshot.bytes(snapshot.freeBytes)))
                Text(monitor.enabled && snapshot.isFresh(at: context.date)
                     ? (snapshot.issues.isEmpty ? L10n.text("관측 상태 보기") : L10n.text("확인이 필요한 상태"))
                     : L10n.text("이전 관측 기록"))
                Text(snapshot.date.formatted(date: .omitted, time: .shortened))
            } else {
                Text(L10n.text("관측 정보 없음"))
            }
        }
        Divider()
        Button(L10n.text("Mac 상태 열기")) {
            openWindow(id: "main")
            monitor.showHealth = true
            NSApp.activate(ignoringOtherApps: true)
        }
        if #available(macOS 14.0, *) {
            SettingsLink { Text(L10n.text("설정…")) }
        } else {
            Button(L10n.text("설정…")) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        Divider()
        Button(L10n.text("Modore 종료")) { NSApp.terminate(nil) }
    }
}
