import SwiftUI
import AppKit

/// Presents `SettingsView()` in a regular NSWindow. The SwiftUI `Settings { … }`
/// scene + `showSettingsWindow:` action don't fire for `LSUIElement` apps, so
/// menu-bar-accessory builds need to manage the window themselves. We also flip
/// `NSApp.setActivationPolicy` to `.regular` while the window is open so it can
/// take focus, then back to `.accessory` on close so the Dock icon doesn't stick.
@MainActor
final class SettingsWindowManager: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowManager()
    private var windowController: NSWindowController?

    func openSettings() {
        if windowController == nil {
            let host = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: host)
            window.title = "MeterBar Settings"
            window.styleMask = [.titled, .closable, .resizable]
            window.setContentSize(NSSize(width: 500, height: 620))
            window.center()
            window.delegate = self
            window.isReleasedWhenClosed = false
            windowController = NSWindowController(window: window)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
