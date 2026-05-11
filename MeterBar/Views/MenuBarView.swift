import SwiftUI
import AppKit

// Which service rows are currently expanded. The set lives in AppStorage so that
// the user's choice persists across app launches.
enum ExpandedCard: String, Equatable, Hashable {
    case claudeCode
    case codexCli
    case cursor
}

struct MenuBarView: View {
    @StateObject private var dataManager = UsageDataManager.shared
    @StateObject private var authManager = AuthenticationManager.shared
    @StateObject private var claudeCodeService = ClaudeCodeLocalService.shared
    @StateObject private var codexCliService = CodexCliLocalService.shared
    @StateObject private var cursorService = CursorLocalService.shared

    // Comma-separated raw values, persisted across launches.
    // Set<ExpandedCard> isn't directly @AppStorage-compatible, so we serialize manually.
    @AppStorage("expandedCardsRaw") private var expandedCardsRaw: String = ""

    private var expandedCards: Binding<Set<ExpandedCard>> {
        Binding(
            get: {
                Set(self.expandedCardsRaw.split(separator: ",").compactMap {
                    ExpandedCard(rawValue: String($0))
                })
            },
            set: { newValue in
                self.expandedCardsRaw = newValue.map(\.rawValue).sorted().joined(separator: ",")
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .help("Settings")

                Text("MeterBar")
                    .font(.headline)

                Spacer()

                Button(action: {
                    Task {
                        await dataManager.refreshAll()
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh now")
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Service Cards
            ScrollView {
                VStack(spacing: 12) {
                    // Claude: Show Claude Code if available, otherwise Claude API
                    // Priority: Claude Code (easier setup) > Claude API (requires admin key)
                    if claudeCodeService.hasAccess {
                        // User has Claude Code logged in - show that
                        ClaudeCodeServiceRow(
                            hasAccess: claudeCodeService.hasAccess,
                            metrics: dataManager.metrics[.claudeCode],
                            expandedCards: expandedCards
                        )
                    } else if authManager.isClaudeAuthenticated {
                        // User has Claude API key configured - show that
                        ServiceRowView(
                            service: .claude,
                            isAuthenticated: authManager.isClaudeAuthenticated,
                            metrics: dataManager.metrics[.claude]
                        )
                    } else {
                        // Neither configured - show Claude Code with login prompt
                        ClaudeCodeServiceRow(
                            hasAccess: false,
                            metrics: nil,
                            expandedCards: expandedCards
                        )
                    }

                    // Codex CLI (local auth from ~/.codex/auth.json)
                    CodexCliServiceRow(
                        hasAccess: codexCliService.hasAccess,
                        metrics: dataManager.metrics[.codexCli],
                        expandedCards: expandedCards
                    )

                    // Cursor (Local)
                    CursorServiceRow(
                        hasAccess: cursorService.hasAccess,
                        metrics: dataManager.metrics[.cursor],
                        expandedCards: expandedCards
                    )
                }
                .padding()
            }
        }
        .frame(width: 320, height: 500)
    }

    private func openSettings() {
        SettingsWindowManager.shared.openSettings()
    }
}

// MARK: - Service Row View

struct ServiceRowView: View {
    let service: ServiceType
    let isAuthenticated: Bool
    let metrics: UsageMetrics?

    @StateObject private var authManager = AuthenticationManager.shared
    @State private var isExpanded: Bool = false
    @State private var apiKeyInput: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: service.iconName)
                    .foregroundColor(headerColor)
                Text(service.displayName)
                    .font(.headline)
                Spacer()

                if isAuthenticated {
                    if let metrics = metrics {
                        StatusIndicator(status: metrics.overallStatus)
                    }

                    // Show gear button to manage key when authenticated
                    Button(action: { isExpanded.toggle() }) {
                        Image(systemName: isExpanded ? "chevron.up" : "gearshape")
                            .font(.caption)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                } else {
                    Button(action: { isExpanded.toggle() }) {
                        HStack(spacing: 4) {
                            Image(systemName: isExpanded ? "chevron.up" : "gearshape")
                            Text(isExpanded ? "Close" : "Configure")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if isAuthenticated, let metrics = metrics {
                Divider()

                // Show usage data
                if let sessionLimit = metrics.sessionLimit {
                    LimitRow(title: "Session", limit: sessionLimit)
                }

                if let weeklyLimit = metrics.weeklyLimit {
                    LimitRow(title: "Weekly", limit: weeklyLimit)
                }

                if let codeReviewLimit = metrics.codeReviewLimit {
                    LimitRow(title: "Code Review", limit: codeReviewLimit)
                }

                Text("Updated: \(formatDate(metrics.lastUpdated))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if !isAuthenticated && !isExpanded {
                Text("Not configured")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Inline settings section
            if isExpanded {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    if isAuthenticated {
                        // Show masked key and remove button
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("API Key configured")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Button(action: {
                            removeApiKey()
                            isExpanded = false
                        }) {
                            HStack {
                                Image(systemName: "trash")
                                Text("Remove Key")
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)
                    } else {
                        // Show input field for new key
                        Text(keyPlaceholder)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        SecureField("Paste API key here...", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)

                        HStack {
                            Button(action: {
                                saveApiKey()
                            }) {
                                HStack {
                                    Image(systemName: "checkmark")
                                    Text("Save")
                                }
                                .font(.caption)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(apiKeyInput.isEmpty)

                            Button(action: {
                                openHelpUrl()
                            }) {
                                HStack {
                                    Image(systemName: "questionmark.circle")
                                    Text("Help")
                                }
                                .font(.caption)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private var headerColor: Color {
        if isAuthenticated, let metrics = metrics {
            return metrics.overallStatus.color
        }
        return .gray
    }

    private var keyPlaceholder: String {
        switch service {
        case .claude:
            return "Admin API Key (sk-ant-admin...)"
        case .claudeCode, .codexCli, .cursor:
            return ""
        case .openai:
            return "Admin API Key"
        }
    }

    private func saveApiKey() {
        switch service {
        case .claude:
            _ = authManager.setClaudeAdminKey(apiKeyInput)
        case .claudeCode, .codexCli, .cursor:
            break // These use local auth, not API key
        case .openai:
            _ = authManager.setOpenAIAdminKey(apiKeyInput)
        }
        apiKeyInput = ""
        isExpanded = false
    }

    private func removeApiKey() {
        switch service {
        case .claude:
            authManager.removeClaudeAdminKey()
        case .claudeCode, .codexCli, .cursor:
            break // These use local auth
        case .openai:
            authManager.removeOpenAIAdminKey()
        }
    }

    private func openHelpUrl() {
        let urlString: String
        switch service {
        case .claude:
            urlString = "https://console.anthropic.com/settings/admin-keys"
        case .claudeCode, .codexCli, .cursor:
            return // No help URL for local auth services
        case .openai:
            urlString = "https://platform.openai.com/settings/organization/admin-keys"
        }

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Cursor Service Row (Local)

struct CursorServiceRow: View {
    let hasAccess: Bool
    let metrics: UsageMetrics?
    @Binding var expandedCards: Set<ExpandedCard>

    @StateObject private var cursorService = CursorLocalService.shared
    @StateObject private var dataManager = UsageDataManager.shared

    private var isExpanded: Bool { expandedCards.contains(.cursor) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header - entire row is tappable
            Button(action: {
                if isExpanded { expandedCards.remove(.cursor) } else { expandedCards.insert(.cursor) }
            }) {
                HStack {
                    Image(systemName: ServiceType.cursor.iconName)
                        .foregroundColor(headerColor)
                    Text(ServiceType.cursor.displayName)
                        .font(.headline)
                        .foregroundColor(.primary)

                    // Show compact progress bar when collapsed
                    if !isExpanded, hasAccess, let metrics = metrics, let session = metrics.weeklyLimit {
                        CompactProgressBar(percentage: session.percentage, color: session.statusColor.color)
                    }

                    Spacer()

                    if hasAccess, let metrics = metrics {
                        StatusIndicator(status: metrics.overallStatus)
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded content — no metrics available (no credentials, or
            // credentials present but the most recent refresh failed). Show
            // the recovery affordances; they're a no-op when already authed.
            if isExpanded, metrics == nil {
                Divider()

                Text("Log in to Cursor IDE to enable")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(action: {
                    cursorService.checkAccess()
                    Task { await dataManager.refreshAll() }
                }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Check Again")
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
            }

            // Expanded content — authenticated case
            if isExpanded, hasAccess, let metrics = metrics {
                Divider()

                if let weeklyLimit = metrics.weeklyLimit {
                    LimitRow(title: "Monthly", limit: weeklyLimit)
                }

                if let subscriptionType = cursorService.subscriptionType {
                    HStack {
                        Text(formatSubscriptionType(subscriptionType))
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
                } else {
                    Text("Updated: \(formatDate(metrics.lastUpdated))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private var headerColor: Color {
        if hasAccess, let metrics = metrics {
            return metrics.overallStatus.color
        }
        return .gray
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func formatSubscriptionType(_ type: String) -> String {
        switch type.lowercased() {
        case "pro_plus":
            return "Pro+"
        default:
            return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

// MARK: - Claude Code Service Row (Local Files)

struct ClaudeCodeServiceRow: View {
    let hasAccess: Bool
    let metrics: UsageMetrics?
    @Binding var expandedCards: Set<ExpandedCard>

    @StateObject private var claudeCodeService = ClaudeCodeLocalService.shared
    @StateObject private var dataManager = UsageDataManager.shared

    @State private var importError: String?

    private var isExpanded: Bool { expandedCards.contains(.claudeCode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header - entire row is tappable
            Button(action: {
                if isExpanded { expandedCards.remove(.claudeCode) } else { expandedCards.insert(.claudeCode) }
            }) {
                HStack {
                    Image(systemName: ServiceType.claudeCode.iconName)
                        .foregroundColor(headerColor)
                    Text(ServiceType.claudeCode.displayName)
                        .font(.headline)
                        .foregroundColor(.primary)

                    // Show compact progress bar when collapsed
                    if !isExpanded, hasAccess, let metrics = metrics, let session = metrics.sessionLimit {
                        CompactProgressBar(percentage: session.percentage, color: session.statusColor.color)
                    }

                    Spacer()

                    if hasAccess, let metrics = metrics {
                        StatusIndicator(status: metrics.overallStatus)
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded content — no metrics available (no credentials, or
            // credentials present but the most recent refresh failed). Show
            // the recovery affordances; they're a no-op when already authed.
            if isExpanded, metrics == nil {
                Divider()

                Text("Log in to Claude Code CLI to enable")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Button(action: {
                        importError = nil
                        switch claudeCodeService.importCredentialsFromKeychain() {
                        case .success:
                            Task { await dataManager.refreshAll() }
                        case .failure(let err):
                            if case .apiError(let msg) = err {
                                importError = msg
                            } else {
                                importError = "\(err)"
                            }
                        }
                    }) {
                        HStack {
                            Image(systemName: "key.fill")
                            Text("Import from Keychain")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: {
                        claudeCodeService.checkAccess()
                        Task { await dataManager.refreshAll() }
                    }) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Check Again")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                }

                if let msg = importError {
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Expanded content — authenticated case
            if isExpanded, hasAccess, let metrics = metrics {
                Divider()

                if let sessionLimit = metrics.sessionLimit {
                    LimitRow(title: "Session (5h)", limit: sessionLimit)
                }

                if let weeklyLimit = metrics.weeklyLimit {
                    LimitRow(title: "All Models (7d)", limit: weeklyLimit)
                }

                if let sonnetLimit = metrics.codeReviewLimit {
                    LimitRow(title: "Sonnet (7d)", limit: sonnetLimit)
                }

                if let subscriptionType = claudeCodeService.subscriptionType {
                    HStack {
                        Text(subscriptionType.capitalized)
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
                } else {
                    Text("Updated: \(formatDate(metrics.lastUpdated))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private var headerColor: Color {
        if hasAccess, let metrics = metrics {
            return metrics.overallStatus.color
        }
        return .gray
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Codex CLI Service Row (Local Files)

struct CodexCliServiceRow: View {
    let hasAccess: Bool
    let metrics: UsageMetrics?
    @Binding var expandedCards: Set<ExpandedCard>

    @StateObject private var codexCliService = CodexCliLocalService.shared
    @StateObject private var dataManager = UsageDataManager.shared

    private var isExpanded: Bool { expandedCards.contains(.codexCli) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header - entire row is tappable
            Button(action: {
                if isExpanded { expandedCards.remove(.codexCli) } else { expandedCards.insert(.codexCli) }
            }) {
                HStack {
                    Image(systemName: ServiceType.codexCli.iconName)
                        .foregroundColor(headerColor)
                    Text(ServiceType.codexCli.displayName)
                        .font(.headline)
                        .foregroundColor(.primary)

                    // Show compact progress bar when collapsed
                    if !isExpanded, hasAccess, let metrics = metrics, let session = metrics.sessionLimit {
                        CompactProgressBar(percentage: session.percentage, color: session.statusColor.color)
                    }

                    Spacer()

                    if hasAccess, let metrics = metrics {
                        StatusIndicator(status: metrics.overallStatus)
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded content — no metrics available (no credentials, or
            // credentials present but the most recent refresh failed). Show
            // the recovery affordances; they're a no-op when already authed.
            if isExpanded, metrics == nil {
                Divider()

                Text("Log in to Codex CLI to enable")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(action: {
                    codexCliService.checkAccess()
                    Task { await dataManager.refreshAll() }
                }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Check Again")
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
            }

            // Expanded content — authenticated case
            if isExpanded, hasAccess, let metrics = metrics {
                Divider()

                if let sessionLimit = metrics.sessionLimit {
                    LimitRow(title: "Session (5h)", limit: sessionLimit)
                }

                if let weeklyLimit = metrics.weeklyLimit {
                    LimitRow(title: "Weekly Limit", limit: weeklyLimit)
                }

                if let codeReviewLimit = metrics.codeReviewLimit {
                    LimitRow(title: "Code Review", limit: codeReviewLimit)
                }

                if let subscriptionType = codexCliService.subscriptionType {
                    HStack {
                        Text(subscriptionType.replacingOccurrences(of: "_", with: " ").capitalized)
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
                } else {
                    Text("Updated: \(formatDate(metrics.lastUpdated))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private var headerColor: Color {
        if hasAccess, let metrics = metrics {
            return metrics.overallStatus.color
        }
        return .gray
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Reusable Components

struct ServiceCard: View {
    let metrics: UsageMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: metrics.service.iconName)
                    .foregroundColor(metrics.overallStatus.color)
                Text(metrics.service.displayName)
                    .font(.headline)
                Spacer()
                StatusIndicator(status: metrics.overallStatus)
            }

            Divider()

            if let sessionLimit = metrics.sessionLimit {
                LimitRow(title: "Session", limit: sessionLimit)
            }

            if let weeklyLimit = metrics.weeklyLimit {
                LimitRow(title: "Weekly", limit: weeklyLimit)
            }

            if let codeReviewLimit = metrics.codeReviewLimit {
                LimitRow(title: "Code Review", limit: codeReviewLimit)
            }

            Text("Updated: \(formatDate(metrics.lastUpdated))")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
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

            ProgressView(value: min(max(limit.used, 0), limit.total), total: limit.total)
                .tint(limit.statusColor.color)

            if let resetTime = limit.resetTime {
                Text("Resets: \(formatResetTime(resetTime))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func formatResetTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
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

// MARK: - Compact Progress Bar (for collapsed headers)

struct CompactProgressBar: View {
    let percentage: Double
    let color: Color

    var body: some View {
        ZStack(alignment: .leading) {
            // Background track
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.gray.opacity(0.3))
                .frame(width: 40, height: 4)

            // Progress fill
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 40 * min(max(percentage, 0), 100) / 100, height: 4)
        }
    }
}
