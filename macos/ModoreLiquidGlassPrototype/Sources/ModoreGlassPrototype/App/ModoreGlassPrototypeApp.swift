import SwiftUI
import AppKit

@main
struct ModoreGlassPrototypeApp: App {
    @NSApplicationDelegateAdaptor(PrototypeAppDelegate.self) private var delegate
    @State private var state = PrototypeState()

    var body: some Scene {
        Window("Modore · Liquid Glass Prototype", id: "prototype") {
            PrototypeRootView(state: state)
                .preferredColorScheme(state.appearance.scheme)
                .frame(minWidth: 980, minHeight: 660)
        }
        .defaultSize(width: 1180, height: 790)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("이동") {
                ForEach(Array(WorkspaceArea.allCases.enumerated()), id: \.element) { index, area in
                    Button(area.title) { state.area = area }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            }
            CommandMenu("프로토타입") {
                Picker("외관", selection: $state.appearance) {
                    ForEach(PrototypeAppearance.allCases) { Text($0.rawValue).tag($0) }
                }
                Divider()
                Picker("Mac 상태 예시", selection: $state.scenario) {
                    ForEach(HealthScenario.allCases) { Text($0.rawValue).tag($0) }
                }
            }
        }
    }
}

final class PrototypeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
