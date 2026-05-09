import SwiftUI
import UserNotifications
import AppKit

@main
struct MeterBarApp: App {
    @StateObject private var dataManager = UsageDataManager.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        print("═══════════════════════════════════════")
        print("🎯 MeterBar: App Initializing")
        print("═══════════════════════════════════════")
    }

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var notificationDeduper = NotificationDeduper()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 MeterBar: Application did finish launching")
        
        // Create menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        guard let button = statusItem?.button else {
            print("❌ Failed to create status item button")
            return
        }
        
        // Set up the menu bar icon with 3 progress bars
        let image = createMenuBarIcon()
        image.isTemplate = true
        button.image = image
        
        button.action = #selector(handleStatusItemClick)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "MeterBar"
        
        // Create popover
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 320, height: 500)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(rootView: MenuBarView())

        // Setup notifications (also handles initial data refresh)
        setupNotifications()

        // Listen for the widget's refresh button (Darwin notification posted
        // by RefreshUsageIntent in the widget extension).
        setupWidgetRefreshListener()
    }

    private func setupWidgetRefreshListener() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    Task { @MainActor in
                        await UsageDataManager.shared.refreshAll()
                    }
                }
            },
            MeterBarSignals.widgetRefreshRequested,
            nil,
            .deliverImmediately
        )
    }
    
    @objc func handleStatusItemClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusBarMenu()
        } else {
            togglePopover()
        }
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button,
              let popover = popover else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showStatusBarMenu() {
        let menu = NSMenu()

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(settingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit MeterBar", action: #selector(quitFromMenu), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func refreshFromMenu() {
        Task { @MainActor in
            await UsageDataManager.shared.refreshAll()
        }
    }

    @objc private func settingsFromMenu() {
        SettingsWindowManager.shared.openSettings()
    }

    @objc private func quitFromMenu() {
        NSApplication.shared.terminate(nil)
    }
    
    private func setupNotifications() {
        // Check current authorization status first
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                // Request permission only if not yet determined
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error = error {
                        print("Notification permission error: \(error)")
                    } else if !granted {
                        print("Notification permission denied by user")
                    }
                }
            case .denied:
                print("Notification permission was previously denied. User can enable in System Settings.")
            case .authorized, .provisional, .ephemeral:
                // Already authorized, no action needed
                break
            @unknown default:
                break
            }
        }
        
        // Monitor usage and send notifications
        Task {
            await monitorUsage()
        }
    }
    
    @MainActor
    private func monitorUsage() async {
        // Initial refresh on app launch
        await UsageDataManager.shared.refreshAll()

        // Check for approaching limits periodically
        // Note: UsageDataManager handles its own 15-minute auto-refresh
        // This loop just checks metrics for notification purposes
        while true {
            for (_, metrics) in UsageDataManager.shared.metrics {
                checkAndNotify(metrics: metrics)
            }

            // Wait 5 minutes before next notification check
            try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
        }
    }
    
    private func checkAndNotify(metrics: UsageMetrics) {
        let entries: [(name: String, limit: UsageLimit)] = [
            ("session", metrics.sessionLimit),
            ("weekly", metrics.weeklyLimit),
            ("codeReview", metrics.codeReviewLimit)
        ].compactMap { name, limit in limit.map { (name, $0) } }

        for (name, limit) in entries {
            let tier: NotificationDeduper.Tier?
            if limit.percentage >= 100 {
                tier = .reached
            } else if limit.percentage >= 90 {
                tier = .warning
            } else {
                tier = nil
            }
            guard let tier else { continue }

            let key = NotificationDeduper.Key(
                service: metrics.service,
                limitName: name,
                tier: tier
            )
            guard notificationDeduper.shouldNotify(key: key, currentResetTime: limit.resetTime) else {
                continue
            }

            switch tier {
            case .reached:
                sendNotification(
                    title: "\(metrics.service.displayName) Limit Reached",
                    body: "You've reached your usage limit"
                )
            case .warning:
                sendNotification(
                    title: "\(metrics.service.displayName) Usage Warning",
                    body: "You're at \(Int(limit.percentage))% of your limit"
                )
            }
        }
    }
    
    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    private func createMenuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let barHeight: CGFloat = 3
            let barSpacing: CGFloat = 2
            let cornerRadius: CGFloat = 1.5

            // Three bars with different widths (like progress indicators)
            let barWidths: [CGFloat] = [0.35, 0.55, 0.85] // 35%, 55%, 85%
            let totalBarsHeight = (barHeight * 3) + (barSpacing * 2)
            let startY = (rect.height - totalBarsHeight) / 2

            for (index, fillPercent) in barWidths.enumerated() {
                let y = startY + CGFloat(index) * (barHeight + barSpacing)
                let barWidth = rect.width * fillPercent

                let barRect = NSRect(x: 0, y: y, width: barWidth, height: barHeight)
                let path = NSBezierPath(roundedRect: barRect, xRadius: cornerRadius, yRadius: cornerRadius)
                NSColor.black.setFill()
                path.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

