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
    }
}
