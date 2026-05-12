import ArgumentParser
import Foundation

@main
struct MeterBarCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meterbar",
        abstract: "Track AI coding assistant usage from the command line",
        version: "1.0.0",
        subcommands: [Usage.self, Cost.self],
        defaultSubcommand: Usage.self
    )
}

struct Usage: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show current usage metrics"
    )

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    @Option(name: .shortAndLong, help: "Filter by provider (claude, openai, cursor, codex)")
    var provider: String?

    func run() throws {
        let metrics = loadCachedMetrics()

        if metrics.isEmpty {
            if json {
                print("{\"error\": \"No cached metrics found. Open MeterBar app to fetch data.\"}")
            } else {
                print("No cached metrics found.")
                print("Open MeterBar app to fetch usage data first.")
            }
            return
        }

        let filtered: [String: ServiceMetrics]
        if let provider = provider?.lowercased() {
            filtered = metrics.filter { Self.matchesProvider($0.key, query: provider) }
        } else {
            filtered = metrics
        }

        if json {
            printJSON(filtered)
        } else {
            printText(filtered)
        }
    }

    /// Cache key shared with the main app. Bumped to `_v2` after `UsageMetrics`
    /// switched from a fixed `sessionLimit/weeklyLimit/codeReviewLimit` triplet
    /// to an ordered `[UsageLimit]` array. Must stay in sync with
    /// `SharedDataStore.metricsKey` and `UsageDataManager.cacheKey`.
    private static let cacheKey = "cached_usage_metrics_v2"

    private func loadCachedMetrics() -> [String: ServiceMetrics] {
        let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.jmdeejay.meterbar"
        )

        if let containerURL = containerURL {
            let path = containerURL.appendingPathComponent("\(Self.cacheKey).json")
            if FileManager.default.fileExists(atPath: path.path),
               let data = try? Data(contentsOf: path),
               let decoded = try? JSONDecoder().decode([String: ServiceMetrics].self, from: data) {
                return decoded
            }
        }

        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let decoded = try? JSONDecoder().decode([String: ServiceMetrics].self, from: data) {
            return decoded
        }
        return [:]
    }

    static func matchesProvider(_ key: String, query: String) -> Bool {
        let lowered = key.lowercased()
        if lowered.contains(query) { return true }
        switch query {
        case "openai", "chatgpt":
            return lowered == "codex cli" || lowered == "openai"
        case "anthropic", "claude":
            return lowered.contains("claude")
        default:
            return false
        }
    }

    private func printJSON(_ metrics: [String: ServiceMetrics]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(metrics),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }

    private func printText(_ metrics: [String: ServiceMetrics]) {
        print("╭─────────────────────────────────────────╮")
        print("│             MeterBar Usage              │")
        print("╰─────────────────────────────────────────╯")
        print()

        for (service, metric) in metrics.sorted(by: { $0.key < $1.key }) {
            let displayName = service.replacingOccurrences(of: "_", with: " ").capitalized
            print("▸ \(displayName)")

            for limit in metric.limits {
                printLimit("  \(limit.verboseLabel)", limit)
            }
            print()
        }
    }

    private func printLimit(_ label: String, _ limit: UsageLimit) {
        let percent = limit.percentage
        let bar = progressBar(percent: percent, width: 20)
        let status = statusEmoji(percent: percent)

        print("\(label): \(bar) \(String(format: "%.0f%%", percent)) \(status)")
        print("    \(limit.used)/\(limit.total) used")
        if let reset = limit.resetTime {
            print("    Resets: \(formatDate(reset))")
        }
    }

    private func progressBar(percent: Double, width: Int) -> String {
        let filled = Int((percent / 100) * Double(width))
        let empty = width - filled
        return "[" + String(repeating: "█", count: filled) + String(repeating: "░", count: empty) + "]"
    }

    private func statusEmoji(percent: Double) -> String {
        if percent < 50 { return "✓" }
        if percent < 80 { return "⚠" }
        return "✗"
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct Cost: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show token costs from local sessions"
    )

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    @Option(name: .shortAndLong, help: "Number of days to scan (default: 30)")
    var days: Int = 30

    func run() throws {
        let costs = scanClaudeCosts(days: days)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(costs),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            printCosts(costs)
        }
    }

    private func scanClaudeCosts(days: Int) -> CostResult {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")

        var totalInput = 0
        var totalOutput = 0
        var totalCacheCreation = 0
        var totalCacheRead = 0
        var sessionCount = 0

        guard FileManager.default.fileExists(atPath: claudeDir.path) else {
            return CostResult(provider: "claude_code", inputTokens: 0, outputTokens: 0,
                            cacheCreationTokens: 0, cacheReadTokens: 0, estimatedCostUSD: 0,
                            sessionCount: 0, periodDays: days)
        }

        do {
            let projectDirs = try FileManager.default.contentsOfDirectory(at: claudeDir, includingPropertiesForKeys: nil)

            for projectDir in projectDirs {
                let jsonlFiles = (try? FileManager.default.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil)) ?? []

                for jsonlFile in jsonlFiles where jsonlFile.pathExtension == "jsonl" {
                    let attrs = try? jsonlFile.resourceValues(forKeys: [.contentModificationDateKey])
                    guard let modDate = attrs?.contentModificationDate, modDate >= cutoffDate else { continue }

                    if let data = try? Data(contentsOf: jsonlFile),
                       let content = String(data: data, encoding: .utf8) {
                        for line in content.components(separatedBy: .newlines) where !line.isEmpty {
                            if let lineData = line.data(using: .utf8),
                               let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                               let message = json["message"] as? [String: Any],
                               let usage = message["usage"] as? [String: Any] {
                                totalInput += usage["input_tokens"] as? Int ?? 0
                                totalOutput += usage["output_tokens"] as? Int ?? 0
                                totalCacheCreation += usage["cache_creation_input_tokens"] as? Int ?? 0
                                totalCacheRead += usage["cache_read_input_tokens"] as? Int ?? 0
                            }
                        }
                        sessionCount += 1
                    }
                }
            }
        } catch {
            // Ignore errors
        }

        // Calculate cost (Sonnet pricing)
        let inputCost = Double(totalInput) / 1_000_000 * 3.0
        let outputCost = Double(totalOutput) / 1_000_000 * 15.0
        let cacheCreationCost = Double(totalCacheCreation) / 1_000_000 * 3.75
        let cacheReadCost = Double(totalCacheRead) / 1_000_000 * 0.30
        let totalCost = inputCost + outputCost + cacheCreationCost + cacheReadCost

        return CostResult(
            provider: "claude_code",
            inputTokens: totalInput,
            outputTokens: totalOutput,
            cacheCreationTokens: totalCacheCreation,
            cacheReadTokens: totalCacheRead,
            estimatedCostUSD: totalCost,
            sessionCount: sessionCount,
            periodDays: days
        )
    }

    private func printCosts(_ costs: CostResult) {
        print("╭─────────────────────────────────────────╮")
        print("│          MeterBar Cost Tracker          │")
        print("╰─────────────────────────────────────────╯")
        print()
        print("Provider: Claude Code")
        print("Period: Last \(costs.periodDays) days")
        print("Sessions scanned: \(costs.sessionCount)")
        print()
        print("Tokens:")
        print("  Input:          \(formatNumber(costs.inputTokens))")
        print("  Output:         \(formatNumber(costs.outputTokens))")
        print("  Cache Creation: \(formatNumber(costs.cacheCreationTokens))")
        print("  Cache Read:     \(formatNumber(costs.cacheReadTokens))")
        print()
        print("Estimated Cost: $\(String(format: "%.2f", costs.estimatedCostUSD))")
        print("Daily Average:  $\(String(format: "%.2f", costs.estimatedCostUSD / Double(costs.periodDays)))/day")
    }

    private func formatNumber(_ num: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: num)) ?? "\(num)"
    }
}

// MARK: - Models

struct ServiceMetrics: Codable {
    let limits: [UsageLimit]
}

struct UsageLimit: Codable {
    let compactLabel: String
    let verboseLabel: String
    let used: Double
    let total: Double
    let resetTime: Date?

    var percentage: Double {
        guard total > 0 else { return 0 }
        return (used / total) * 100
    }
}

struct CostResult: Codable {
    let provider: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let estimatedCostUSD: Double
    let sessionCount: Int
    let periodDays: Int
}
