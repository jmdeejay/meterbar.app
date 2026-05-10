import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Shared Types (duplicated for Widget target)

enum ServiceType: String, Codable, CaseIterable, Identifiable {
    case claudeCode = "Claude Code"
    case codexCli = "Codex CLI"
    case cursor = "Cursor"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codexCli: return "OpenAI Codex"
        case .cursor: return "Cursor"
        }
    }

    var compactDisplayName: String {
        ServiceLabels.compactDisplayName(for: rawValue)
    }

    func sessionLabel(verbose: Bool) -> String {
        ServiceLabels.sessionLabel(for: rawValue, verbose: verbose)
    }

    func weeklyLabel(verbose: Bool) -> String {
        ServiceLabels.weeklyLabel(for: rawValue, verbose: verbose)
    }

    func codeReviewLabel(verbose: Bool) -> String {
        ServiceLabels.codeReviewLabel(for: rawValue, verbose: verbose)
    }

    var iconName: String {
        switch self {
        case .claudeCode: return "ClaudeIcon"
        case .codexCli: return "CodexIcon"
        case .cursor: return "CursorIcon"
        }
    }

    var sortOrder: Int {
        switch self {
        case .claudeCode: return 0
        case .codexCli: return 1
        case .cursor: return 2
        }
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

struct UsageLimit: Codable, Equatable {
    let used: Double
    let total: Double
    let resetTime: Date?

    var percentage: Double {
        guard total > 0 else { return 0 }
        return min(100, max(0, (used / total) * 100))
    }

    var clampedUsed: Double {
        return max(0, min(used, total))
    }

    var clampedTotal: Double {
        return max(0.001, total)
    }

    var remaining: Double {
        return max(0, total - used)
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
        } else {
            return .good
        }
    }
}

struct UsageMetrics: Codable, Identifiable {
    let id: UUID
    let service: ServiceType
    let sessionLimit: UsageLimit?
    let weeklyLimit: UsageLimit?
    let codeReviewLimit: UsageLimit?
    let lastUpdated: Date

    init(
        service: ServiceType,
        sessionLimit: UsageLimit? = nil,
        weeklyLimit: UsageLimit? = nil,
        codeReviewLimit: UsageLimit? = nil,
        lastUpdated: Date = Date()
    ) {
        self.id = UUID()
        self.service = service
        self.sessionLimit = sessionLimit
        self.weeklyLimit = weeklyLimit
        self.codeReviewLimit = codeReviewLimit
        self.lastUpdated = lastUpdated
    }

    var overallStatus: UsageStatus {
        let limits = [sessionLimit, weeklyLimit, codeReviewLimit].compactMap { $0 }
        guard !limits.isEmpty else { return .good }

        if limits.contains(where: { $0.isAtLimit }) {
            return .critical
        } else if limits.contains(where: { $0.isNearLimit }) {
            return .warning
        } else {
            return .good
        }
    }

    var hasData: Bool {
        return sessionLimit != nil || weeklyLimit != nil || codeReviewLimit != nil
    }
}

// MARK: - Widget

struct UsageWidget: Widget {
    let kind: String = "UsageWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageWidgetProvider()) { entry in
            UsageWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("MeterBar")
        .description("Track your AI coding assistant usage limits")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct UsageWidgetEntry: TimelineEntry {
    let date: Date
    let metrics: [ServiceType: UsageMetrics]

    var sortedServices: [ServiceType] {
        metrics.keys.sorted { $0.sortOrder < $1.sortOrder }
    }
}

struct UsageWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageWidgetEntry {
        UsageWidgetEntry(
            date: Date(),
            metrics: [
                .codexCli: UsageMetrics(
                    service: .codexCli,
                    weeklyLimit: UsageLimit(used: 30, total: 100, resetTime: nil)
                ),
                .cursor: UsageMetrics(
                    service: .cursor,
                    weeklyLimit: UsageLimit(used: 50, total: 100, resetTime: nil)
                ),
                .claudeCode: UsageMetrics(
                    service: .claudeCode,
                    weeklyLimit: UsageLimit(used: 90, total: 100, resetTime: nil)
                )
            ]
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageWidgetEntry) -> Void) {
        let entry = UsageWidgetEntry(
            date: Date(),
            metrics: SharedDataStore.shared.loadMetrics()
        )
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageWidgetEntry>) -> Void) {
        let cachedMetrics = SharedDataStore.shared.loadMetrics()
        let entry = UsageWidgetEntry(
            date: Date(),
            metrics: cachedMetrics
        )

        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

struct UsageWidgetEntryView: View {
    var entry: UsageWidgetEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(entry: entry)
        case .systemMedium:
            MediumWidgetView(entry: entry)
        case .systemLarge:
            LargeWidgetView(entry: entry)
        default:
            SmallWidgetView(entry: entry)
        }
    }
}

struct EmptyServicesView: View {
    var iconFont: Font = .largeTitle
    var textFont: Font = .caption

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle")
                .font(iconFont)
                .foregroundColor(.orange)
            Text("No services connected")
                .font(textFont)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WidgetRefreshButton: View {
    var topPadding: CGFloat = 8
    var trailingPadding: CGFloat = 8
    var iconSize: CGFloat = 16

    var body: some View {
        Group {
            if #available(macOS 14.0, *) {
                Button(intent: RefreshUsageIntent()) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: iconSize, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, topPadding)
        .padding(.trailing, trailingPadding)
    }
}

struct ServiceMiniView: View {
    let metrics: UsageMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(metrics.service.iconName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                Text(metrics.service.compactDisplayName)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                WidgetStatusIndicator(status: metrics.overallStatus)
            }
            if let session = metrics.sessionLimit {
                MiniLimitRow(label: metrics.service.sessionLabel(verbose: false), limit: session, font: .system(size: 9))
            }
            if let weekly = metrics.weeklyLimit {
                MiniLimitRow(label: metrics.service.weeklyLabel(verbose: false), limit: weekly, font: .system(size: 9))
            }
            if let codeReview = metrics.codeReviewLimit {
                MiniLimitRow(label: metrics.service.codeReviewLabel(verbose: false), limit: codeReview, font: .system(size: 9))
            }
        }
    }
}

struct SmallWidgetView: View {
    let entry: UsageWidgetEntry

    var body: some View {
        Group {
            if entry.metrics.isEmpty {
                EmptyServicesView(iconFont: .title2, textFont: .caption2)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entry.sortedServices.prefix(3), id: \.self) { service in
                        if let metrics = entry.metrics[service] {
                            ServiceMiniView(metrics: metrics)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(4)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct MediumWidgetView: View {
    let entry: UsageWidgetEntry

    var body: some View {
        let services = Array(entry.sortedServices.prefix(3))
        Group {
            if entry.metrics.isEmpty {
                EmptyServicesView(iconFont: .title, textFont: .caption)
            } else if services.count == 1 {
                // 1 service: switch to the wide row layout
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(services, id: \.self) { service in
                        if let metrics = entry.metrics[service] {
                            ServiceCompactView(metrics: metrics)
                        }
                    }
                }
            } else {
                // 2–3 services: column layout, splitting width evenly.
                HStack(alignment: .top, spacing: 10) {
                    ForEach(services, id: \.self) { service in
                        if let metrics = entry.metrics[service] {
                            ServiceColumnView(metrics: metrics)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topTrailing) {
            WidgetRefreshButton(topPadding: -10, trailingPadding: 2, iconSize: 12)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct LargeWidgetView: View {
    let entry: UsageWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if entry.metrics.isEmpty {
                EmptyServicesView()
            } else {
                ForEach(entry.sortedServices.prefix(7), id: \.self) { service in
                    if let metrics = entry.metrics[service] {
                        ServiceCompactView(metrics: metrics)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topTrailing) {
            WidgetRefreshButton(topPadding: -10, trailingPadding: 4, iconSize: 12)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct ServiceColumnView: View {
    let metrics: UsageMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(metrics.service.iconName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                Text(metrics.service.compactDisplayName)
                    .font(.caption2)
                    .bold()
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                WidgetStatusIndicator(status: metrics.overallStatus)
            }
            if let session = metrics.sessionLimit {
                MiniLimitRow(label: metrics.service.sessionLabel(verbose: true), limit: session, font: .system(size: 10), stackedLabel: true)
            }
            if let weekly = metrics.weeklyLimit {
                MiniLimitRow(label: metrics.service.weeklyLabel(verbose: true), limit: weekly, font: .system(size: 10), stackedLabel: true)
            }
            if let codeReview = metrics.codeReviewLimit {
                MiniLimitRow(label: metrics.service.codeReviewLabel(verbose: true), limit: codeReview, font: .system(size: 10), stackedLabel: true)
            }
        }
    }
}

struct ServiceCompactView: View {
    let metrics: UsageMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(metrics.service.iconName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
                Text(metrics.service.displayName)
                    .font(.subheadline)
                    .bold()
                Spacer()
                WidgetStatusIndicator(status: metrics.overallStatus)
            }

            if let session = metrics.sessionLimit {
                MiniLimitRow(label: metrics.service.sessionLabel(verbose: true), limit: session, font: .caption, showsResetTime: true, barHeight: 7)
            }
            if let weekly = metrics.weeklyLimit {
                MiniLimitRow(label: metrics.service.weeklyLabel(verbose: true), limit: weekly, font: .caption, showsResetTime: true, barHeight: 7)
            }
            if let codeReview = metrics.codeReviewLimit {
                MiniLimitRow(label: metrics.service.codeReviewLabel(verbose: true), limit: codeReview, font: .caption, showsResetTime: true, barHeight: 7)
            }
        }
    }
}

struct MiniLimitRow: View {
    let label: String
    let limit: UsageLimit
    let font: Font
    var showsResetTime: Bool = false
    var barHeight: CGFloat? = nil
    var stackedLabel: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if stackedLabel {
                Text(label)
                    .font(font)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    progressBar
                    Text("\(Int(limit.percentage))%")
                        .font(font)
                }
            } else {
                HStack(spacing: 4) {
                    Text(label)
                        .font(font)
                    progressBar
                    Text("\(Int(limit.percentage))%")
                        .font(font)
                }
            }
            if showsResetTime, let reset = limit.resetTime {
                Text("Resets: \(Self.formatResetTime(reset))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if let barHeight {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.25))
                    Capsule()
                        .fill(limit.statusColor.color)
                        .frame(width: geo.size.width * (limit.clampedUsed / limit.clampedTotal))
                }
            }
            .frame(height: barHeight)
        } else {
            ProgressView(value: limit.clampedUsed, total: limit.clampedTotal)
                .tint(limit.statusColor.color)
        }
    }

    private static func formatResetTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct ServiceDetailView: View {
    let metrics: UsageMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(metrics.service.iconName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
                Text(metrics.service.displayName)
                    .font(.headline)
                Spacer()
                WidgetStatusIndicator(status: metrics.overallStatus)
            }

            if let sessionLimit = metrics.sessionLimit {
                LimitDetailView(title: "Session", limit: sessionLimit)
            }

            if let weeklyLimit = metrics.weeklyLimit {
                LimitDetailView(title: "Weekly", limit: weeklyLimit)
            }

            if let codeReviewLimit = metrics.codeReviewLimit {
                LimitDetailView(title: "Code Review", limit: codeReviewLimit)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
}

struct LimitDetailView: View {
    let title: String
    let limit: UsageLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                Spacer()
                Text("\(Int(limit.percentage))%")
                    .font(.caption)
                    .bold()
            }

            ProgressView(value: limit.clampedUsed, total: limit.clampedTotal)
                .tint(limit.statusColor.color)

            Text("\(formatNumber(limit.used)) / \(formatNumber(limit.total))")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func formatNumber(_ value: Double) -> String {
        if value >= 1000 {
            return String(format: "%.1fk", value / 1000)
        }
        return String(format: "%.0f", value)
    }
}

struct WidgetStatusIndicator: View {
    let status: UsageStatus

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 8, height: 8)
    }
}
