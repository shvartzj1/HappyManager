import SwiftUI
import ServiceManagement

@main
struct HappyManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate?

    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var processManager = ProcessManager.shared
    var terminalWindows: [UUID: NSWindow] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "face.smiling.inverse", accessibilityDescription: "Happy Manager")
            button.action = #selector(togglePopover)
        }

        // Create popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 500)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ContentView())

        // Start monitoring configured instances
        processManager.startAllConfigured()
    }

    @objc func togglePopover() {
        if let button = statusItem.button {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func openTerminalWindow(instanceId: UUID, title: String) {
        // If window already open, bring to front
        if let existing = terminalWindows[instanceId] {
            existing.makeKeyAndOrderFront(self)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create new window with terminal view
        let view = TerminalWindowView(instanceId: instanceId, title: title)
        let hostingController = NSHostingController(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = title
        window.minSize = NSSize(width: 900, height: 500)
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(self)

        terminalWindows[instanceId] = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // Remove window from tracking dictionary
        terminalWindows = terminalWindows.filter { $0.value !== window }
    }
}
