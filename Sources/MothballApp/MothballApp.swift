import SwiftUI
import MothballCore

@main
struct MothballApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Mothball") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .windowResizability(.contentMinSize)

        // macOS surfaces this scene via the standard Cmd+, shortcut
        // and the "Settings..." menu item — no custom plumbing needed.
        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if !model.hasAcceptedFirstRun {
                FirstRunView()
            } else {
                ScanView()
            }
        }
        .sheet(item: $model.confirmation) { request in
            ConfirmView(request: request)
        }
        .sheet(item: $model.activeArchiveRun) { run in
            ProgressOverlay(run: run)
        }
        .sheet(item: $model.lastArchiveSummary) { summary in
            ArchiveSummaryView(summary: summary)
        }
    }
}
