import AppKit
import Foundation
import SwiftUI

struct UsageLimit: Equatable, Identifiable {
    let id = UUID()
    let compactLabel: String
    let verboseLabel: String
    let used: Double
    let total: Double
    let resetTime: Date?

    var percentage: Double {
        guard total > 0 else { return 0 }
        return min(100, max(0, (used / total) * 100))
    }

    var isNearLimit: Bool {
        return percentage >= 80
    }

    var isAtLimit: Bool {
        return percentage >= 100
    }

    var statusColor: UsageStatus {
        if isAtLimit {
            return .critical
        } else if isNearLimit {
            return .warning
        }
        return .good
    }
}

enum UsageStatus {
    case good
    case warning
    case critical

    var color: Color {
        switch self {
        case .good: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

enum ServiceType: String, CaseIterable, Identifiable {
    case claudeCode = "Claude Code"
    case codexCli = "Codex CLI"
    case cursor = "Cursor"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codexCli:   return "OpenAI Codex"
        case .cursor:     return "Cursor"
        }
    }

    var iconSymbolName: String {
        switch self {
        case .claudeCode: return "terminal"
        case .codexCli:   return "terminal.fill"
        case .cursor:     return "cursorarrow.click"
        }
    }

    var brandColor: Color {
        switch self {
        case .claudeCode: return Color(red: 224/255, green: 128/255, blue: 0/255)   // #E08000
        case .codexCli:   return Color(red: 144/255, green: 112/255, blue: 240/255) // #9070F0
        case .cursor:     return Color(red:  16/255, green: 192/255, blue: 224/255) // #10C0E0
        }
    }
}

enum BrandIcon {
    private static let assetsRoot: URL = {
        let scriptURL = URL(fileURLWithPath: #filePath)
        return scriptURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MeterBarWidget/Assets.xcassets")
    }()

    static func image(for service: ServiceType, size: CGFloat) -> AnyView {
        let (folder, file): (String, String)
        switch service {
        case .claudeCode: (folder, file) = ("ClaudeIcon.imageset", "claude@2x.png")
        case .codexCli:   (folder, file) = ("CodexIcon.imageset",  "codex@2x.png")
        case .cursor:     (folder, file) = ("CursorIcon.imageset", "cursor@2x.png")
        }
        let path = assetsRoot.appendingPathComponent(folder).appendingPathComponent(file).path
        if let nsImage = NSImage(contentsOfFile: path) {
            return AnyView(
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            )
        }
        return AnyView(
            Image(systemName: "questionmark.square")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .foregroundColor(.secondary)
        )
    }
}

struct UsageMetrics: Identifiable {
    let id = UUID()
    let service: ServiceType
    let limits: [UsageLimit]
    let lastUpdated: Date

    var overallStatus: UsageStatus {
        guard !limits.isEmpty else { return .good }
        if limits.contains(where: { $0.isAtLimit }) {
            return .critical
        } else if limits.contains(where: { $0.isNearLimit }) {
            return .warning
        }
        return .good
    }
}

struct WallpaperView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.06, blue: 0.12),
                    Color(red: 0.09, green: 0.18, blue: 0.28),
                    Color(red: 0.24, green: 0.14, blue: 0.35)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 220, height: 220)
                .offset(x: -100, y: -120)
                .blur(radius: 10)

            Circle()
                .fill(Color.white.opacity(0.07))
                .frame(width: 260, height: 260)
                .offset(x: 120, y: 130)
                .blur(radius: 12)
        }
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let state: NSVisualEffectView.State

    init(
        material: NSVisualEffectView.Material,
        blendingMode: NSVisualEffectView.BlendingMode = .withinWindow,
        state: NSVisualEffectView.State = .active
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
    }
}

struct MacOSPopoverBackground: View {
    var body: some View {
        VisualEffectView(material: .popover)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct MacOSCardBackground: View {
    var body: some View {
        VisualEffectView(material: .contentBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct MacOSWidgetBackground: View {
    var body: some View {
        VisualEffectView(material: .sidebar)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct MenuBarSnapshotView: View {
    let claudeCodeMetrics: UsageMetrics
    let codexMetrics: UsageMetrics
    let cursorMetrics: UsageMetrics

    var body: some View {
        ZStack {
            MacOSPopoverBackground()
            VStack(spacing: 0) {
                header
                Divider()
                ScrollView {
                    VStack(spacing: 12) {
                        ClaudeCodeSnapshotRow(metrics: claudeCodeMetrics, subscriptionLabel: "Max")
                        ServiceSnapshotRow(metrics: codexMetrics, subscriptionLabel: "Plus")
                        CursorSnapshotRow(metrics: cursorMetrics, subscriptionLabel: "Pro")
                    }
                    .padding()
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(width: 320, height: 500)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "gearshape")
                .foregroundColor(.primary)
            Text("MeterBar")
                .font(.headline)
            Spacer()
            Image(systemName: "arrow.clockwise")
                .foregroundColor(.primary)
        }
        .padding()
        .background(VisualEffectView(material: .headerView))
    }
}

struct ServiceSnapshotRow: View {
    let metrics: UsageMetrics
    let subscriptionLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: metrics.service.iconSymbolName).foregroundColor(metrics.service.brandColor)
                Text(metrics.service.displayName)
                    .font(.headline)
                Spacer()
                StatusIndicator(status: metrics.overallStatus)
                Image(systemName: "chevron.up")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            ForEach(metrics.limits) { limit in
                LimitRow(title: limit.verboseLabel, limit: limit)
            }

            HStack {
                Text(subscriptionLabel)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.2))
                    .cornerRadius(4)
                Spacer()
                Text("Updated: \(formatDate(metrics.lastUpdated))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(MacOSCardBackground())
    }
}

struct ClaudeCodeSnapshotRow: View {
    let metrics: UsageMetrics
    let subscriptionLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: metrics.service.iconSymbolName).foregroundColor(metrics.service.brandColor)
                Text(metrics.service.displayName)
                    .font(.headline)
                Spacer()
                StatusIndicator(status: metrics.overallStatus)
                Image(systemName: "chevron.up")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            ForEach(metrics.limits) { limit in
                LimitRow(title: limit.verboseLabel, limit: limit)
            }

            HStack {
                Text(subscriptionLabel)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.2))
                    .cornerRadius(4)
                Spacer()
                Text("Updated: \(formatDate(metrics.lastUpdated))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(MacOSCardBackground())
    }
}

struct CursorSnapshotRow: View {
    let metrics: UsageMetrics
    let subscriptionLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: metrics.service.iconSymbolName).foregroundColor(metrics.service.brandColor)
                Text(metrics.service.displayName)
                    .font(.headline)
                Spacer()
                StatusIndicator(status: metrics.overallStatus)
                Image(systemName: "chevron.up")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            ForEach(metrics.limits) { limit in
                LimitRow(title: limit.verboseLabel, limit: limit)
            }

            HStack {
                Text(subscriptionLabel)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.2))
                    .cornerRadius(4)
                Spacer()
                Text("Updated: \(formatDate(metrics.lastUpdated))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(MacOSCardBackground())
    }
}

struct LimitRow: View {
    let title: String
    let limit: UsageLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                Text("\(Int(limit.percentage))%")
                    .font(.subheadline)
                    .bold()
            }

            UsageProgressBar(progress: limit.total > 0 ? limit.used / limit.total : 0, tint: limit.statusColor.color)

            if let resetTime = limit.resetTime {
                Text("Resets: \(formatResetTime(resetTime))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

struct StatusIndicator: View {
    let status: UsageStatus

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 8, height: 8)
    }
}

struct WidgetMediumSnapshotView: View {
    let metrics: [UsageMetrics]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MacOSWidgetBackground()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(alignment: .top, spacing: 10) {
                ForEach(metrics) { entry in
                    WidgetServiceColumnView(metrics: entry)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(.top, 30)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .padding(.top, 10)
                .padding(.trailing, 14)
        }
        .frame(width: 340, height: 170)
    }
}

struct WidgetServiceColumnView: View {
    let metrics: UsageMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                BrandIcon.image(for: metrics.service, size: 14)
                Text(compactDisplayName(metrics.service))
                    .font(.caption2)
                    .bold()
                    .lineLimit(1)
                Spacer(minLength: 2)
                WidgetStatusIndicator(status: metrics.overallStatus)
            }

            ForEach(metrics.limits) { limit in
                VStack(alignment: .leading, spacing: 2) {
                    Text(limit.verboseLabel)
                        .font(.system(size: 10))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        UsageProgressBar(progress: limit.total > 0 ? limit.used / limit.total : 0, tint: limit.statusColor.color)
                        Text("\(Int(limit.percentage))%")
                            .font(.system(size: 10))
                    }
                }
            }
        }
    }

    private func compactDisplayName(_ service: ServiceType) -> String {
        switch service {
        case .claudeCode: return "Claude"
        case .codexCli:   return "OpenAI"
        case .cursor:     return "Cursor"
        }
    }
}

struct WidgetStatusIndicator: View {
    let status: UsageStatus

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 6, height: 6)
    }
}

struct UsageProgressBar: View {
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(NSColor.separatorColor).opacity(0.25))
                RoundedRectangle(cornerRadius: 3)
                    .fill(tint)
                    .frame(width: geometry.size.width * CGFloat(max(0, min(progress, 1))))
            }
        }
        .frame(height: 6)
    }
}

func formatResetTime(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

func formatDate(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

enum SnapshotError: Error {
    case renderFailed(String)
    case outputFailed(String)
}

@MainActor
func makeWindow<V: View>(
    content: V,
    size: CGSize,
    level: NSWindow.Level,
    hasShadow: Bool,
    isOpaque: Bool
) -> NSWindow {
    let hostingView = NSHostingView(rootView: content.environment(\.colorScheme, .dark))
    hostingView.frame = NSRect(origin: .zero, size: size)

    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.isOpaque = isOpaque
    window.backgroundColor = isOpaque ? .black : .clear
    window.hasShadow = hasShadow
    window.appearance = NSAppearance(named: .darkAqua)
    window.level = level
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.contentView = hostingView
    return window
}

@MainActor
func captureWindow(_ window: NSWindow, to url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = [
        "-l", "\(window.windowNumber)",
        "-t", "png",
        "-o",
        "-x",
        url.path
    ]

    try process.run()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
        throw SnapshotError.outputFailed("screencapture failed for \(url.lastPathComponent)")
    }
}

@main
struct SnapshotRenderer {
    @MainActor
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)

        guard let screen = NSScreen.main else {
            throw SnapshotError.renderFailed("No screen available for screenshots")
        }

        let outputDir = URL(fileURLWithPath: "docs/screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let now = Date()

        let claudeCodeMetrics = UsageMetrics(
            service: .claudeCode,
            limits: [
                UsageLimit(compactLabel: "S", verboseLabel: "Session (5h)", used: 42, total: 100, resetTime: now.addingTimeInterval(2 * 60 * 60)),
                UsageLimit(compactLabel: "W", verboseLabel: "All Models (7d)", used: 78, total: 100, resetTime: now.addingTimeInterval(3 * 24 * 60 * 60)),
                UsageLimit(compactLabel: "Sn", verboseLabel: "Sonnet (7d)", used: 91, total: 100, resetTime: now.addingTimeInterval(3 * 24 * 60 * 60)),
            ],
            lastUpdated: now.addingTimeInterval(-18 * 60)
        )

        let codexMetrics = UsageMetrics(
            service: .codexCli,
            limits: [
                UsageLimit(compactLabel: "S", verboseLabel: "Session (5h)", used: 24, total: 100, resetTime: now.addingTimeInterval(5 * 60 * 60)),
                UsageLimit(compactLabel: "W", verboseLabel: "Weekly", used: 62, total: 100, resetTime: now.addingTimeInterval(6 * 24 * 60 * 60)),
            ],
            lastUpdated: now.addingTimeInterval(-42 * 60)
        )

        let cursorMetrics = UsageMetrics(
            service: .cursor,
            limits: [
                UsageLimit(compactLabel: "API", verboseLabel: "API", used: 26, total: 100, resetTime: now.addingTimeInterval(12 * 24 * 60 * 60)),
                UsageLimit(compactLabel: "M", verboseLabel: "Monthly", used: 26, total: 100, resetTime: now.addingTimeInterval(12 * 24 * 60 * 60)),
            ],
            lastUpdated: now.addingTimeInterval(-95 * 60)
        )

        let menuBarView = MenuBarSnapshotView(
            claudeCodeMetrics: claudeCodeMetrics,
            codexMetrics: codexMetrics,
            cursorMetrics: cursorMetrics
        )

        let widgetView = WidgetMediumSnapshotView(metrics: [claudeCodeMetrics, codexMetrics, cursorMetrics])

        let menuBarSize = CGSize(width: 320, height: 500)
        let widgetSize = CGSize(width: 340, height: 170)
        let menuBarPadding: CGFloat = 18
        let widgetPadding: CGFloat = 24
        let menuBarCanvasSize = CGSize(
            width: menuBarSize.width + menuBarPadding * 2,
            height: menuBarSize.height + menuBarPadding * 2
        )
        let widgetCanvasSize = CGSize(
            width: widgetSize.width + widgetPadding * 2,
            height: widgetSize.height + widgetPadding * 2
        )
        let menuBarCanvas = menuBarView
            .padding(menuBarPadding)
            .frame(width: menuBarCanvasSize.width, height: menuBarCanvasSize.height, alignment: .center)
        let widgetCanvas = ZStack {
            Color.clear
            widgetView
        }
        .frame(width: widgetCanvasSize.width, height: widgetCanvasSize.height, alignment: .center)
        let backdropSize = CGSize(
            width: min(900, screen.visibleFrame.width * 0.8),
            height: min(600, screen.visibleFrame.height * 0.8)
        )
        let backdropOrigin = CGPoint(
            x: screen.visibleFrame.midX - backdropSize.width / 2,
            y: screen.visibleFrame.midY - backdropSize.height / 2
        )
        let inset: CGFloat = 40
        let menuOrigin = CGPoint(
            x: backdropOrigin.x + inset,
            y: backdropOrigin.y + backdropSize.height - menuBarCanvasSize.height - inset
        )
        let widgetOrigin = CGPoint(
            x: backdropOrigin.x + backdropSize.width - widgetCanvasSize.width - inset,
            y: backdropOrigin.y + backdropSize.height - widgetCanvasSize.height - inset
        )

        let backdropWindow = makeWindow(
            content: WallpaperView(),
            size: backdropSize,
            level: .normal,
            hasShadow: false,
            isOpaque: true
        )
        backdropWindow.setFrameOrigin(backdropOrigin)
        backdropWindow.orderFrontRegardless()

        let menuBarWindow = makeWindow(
            content: menuBarCanvas,
            size: menuBarCanvasSize,
            level: .floating,
            hasShadow: false,
            isOpaque: false
        )
        menuBarWindow.setFrameOrigin(menuOrigin)
        menuBarWindow.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        try captureWindow(menuBarWindow, to: outputDir.appendingPathComponent("menubar.png"))
        menuBarWindow.orderOut(nil)

        let widgetWindow = makeWindow(
            content: widgetCanvas,
            size: widgetCanvasSize,
            level: .floating,
            hasShadow: false,
            isOpaque: false
        )
        widgetWindow.setFrameOrigin(widgetOrigin)
        widgetWindow.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        try captureWindow(widgetWindow, to: outputDir.appendingPathComponent("widget-medium.png"))
        widgetWindow.orderOut(nil)
        backdropWindow.orderOut(nil)
    }
}
