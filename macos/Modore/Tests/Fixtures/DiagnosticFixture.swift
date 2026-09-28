// Standalone AppKit fixture for manual end-to-end replay validation.
// Build: swiftc Tests/Fixtures/DiagnosticFixture.swift -o <Fixture.app>/Contents/MacOS/DiagnosticFixture
import AppKit
final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 800, y: 180, width: 600, height: 400),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Modore Replay Fixture"
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let label = NSTextField(labelWithString: "Fixture only — no network or message sending")
        label.frame = NSRect(x: 20, y: 345, width: 550, height: 30); view.addSubview(label)
        let sidebar = NSButton(title: "Hover target", target: nil, action: nil)
        sidebar.frame = NSRect(x: 20, y: 190, width: 150, height: 60); view.addSubview(sidebar)
        let field = NSTextView(frame: NSRect(x: 210, y: 40, width: 360, height: 270))
        field.isRichText = false; field.font = .systemFont(ofSize: 18)
        field.setAccessibilityIdentifier("qa-input")
        view.addSubview(field)
        window.contentView = view
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
withExtendedLifetime(delegate) { app.run() }
