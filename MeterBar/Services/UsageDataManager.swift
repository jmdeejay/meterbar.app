import Foundation
import Combine
import SwiftUI

@MainActor
class UsageDataManager: ObservableObject {
    static let shared = UsageDataManager()

    @Published var metrics: [ServiceType: UsageMetrics] = [:]
    @Published var isLoading: Bool = false
    @Published var lastError: Error?

    @AppStorage("refreshInterval") private var refreshIntervalRaw: Int = RefreshInterval.fifteenMinutes.rawValue

    var refreshInterval: RefreshInterval {
        get { RefreshInterval(rawValue: refreshIntervalRaw) ?? .fifteenMinutes }
        set {
            refreshIntervalRaw = newValue.rawValue
            setupAutoRefresh()
        }
    }

    private let claudeService = ClaudeService.shared
    private let claudeCodeService = ClaudeCodeLocalService.shared
    private let cursorService = CursorLocalService.shared
    private let openaiService = OpenAIService.shared
    private let codexCliService = CodexCliLocalService.shared
    private let authManager = AuthenticationManager.shared

    private var refreshTimer: Timer?
    // v2: UsageMetrics shape changed from `sessionLimit/weeklyLimit/codeReviewLimit`
    // triplets to an ordered `[UsageLimit]` array (each carrying its own label).
    // Bumping the key invalidates v1 caches instead of failing to decode them.
    private let cacheKey = "cached_usage_metrics_v2"
    private let sharedStore = SharedDataStore.shared

    private init() {
        loadCachedData()
        setupAutoRefresh()
    }

    func refreshAll() async {
        isLoading = true
        lastError = nil

        // Re-check local credential files so deleted/added auth files propagate
        // to `hasAccess` before we decide whether to fetch.
        claudeCodeService.checkAccess()
        codexCliService.checkAccess()
        cursorService.checkAccess()

        var newMetrics: [ServiceType: UsageMetrics] = [:]

        // Fetch Claude metrics
        if authManager.isClaudeAuthenticated {
            do {
                let metrics = try await claudeService.fetchUsageMetrics()
                newMetrics[.claude] = metrics
            } catch {
                lastError = error
                print("Failed to fetch Claude metrics: \(error)")
            }
        }

        // Fetch Claude Code metrics (local files)
        if claudeCodeService.hasAccess {
            do {
                let metrics = try await claudeCodeService.fetchUsageMetrics()
                newMetrics[.claudeCode] = metrics
            } catch {
                lastError = error
                // Preserve cached data on transient failures only. A 401 means
                // the OAuth token is dead - keeping the stale section alive in
                // the widget would lie to the user.
                if !isAuthFailure(error), let cachedMetrics = self.metrics[.claudeCode] {
                    newMetrics[.claudeCode] = cachedMetrics
                }
            }
        }

        // Fetch OpenAI API metrics
        if authManager.isOpenAIAuthenticated {
            do {
                let metrics = try await openaiService.fetchUsageMetrics()
                newMetrics[.openai] = metrics
            } catch {
                lastError = error
                print("Failed to fetch OpenAI metrics: \(error)")
            }
        }

        // Fetch Codex CLI metrics (local auth from ~/.codex/auth.json)
        if codexCliService.hasAccess {
            do {
                let metrics = try await codexCliService.fetchUsageMetrics()
                newMetrics[.codexCli] = metrics
            } catch {
                lastError = error
                print("Failed to fetch Codex CLI metrics: \(error)")
                if !isAuthFailure(error), let cachedMetrics = self.metrics[.codexCli] {
                    newMetrics[.codexCli] = cachedMetrics
                }
            }
        }

        // Fetch Cursor metrics (local files)
        if cursorService.hasAccess {
            do {
                let metrics = try await cursorService.fetchUsageMetrics()
                newMetrics[.cursor] = metrics
            } catch {
                lastError = error
                print("Failed to fetch Cursor metrics: \(error)")
                if !isAuthFailure(error), let cachedMetrics = self.metrics[.cursor] {
                    newMetrics[.cursor] = cachedMetrics
                }
            }
        }
        
        // Preserve cached metrics for services that are *authed* but whose
        // fetch failed (graceful degradation). Drop entries for services that
        // are no longer authed so deleted credentials propagate to the widget
        // cache instead of leaving a stale section behind.
        for service in ServiceType.allCases {
            guard newMetrics[service] == nil, let cachedMetric = self.metrics[service] else { continue }
            let isAuthed: Bool
            switch service {
            case .claude:     isAuthed = authManager.isClaudeAuthenticated
            case .claudeCode: isAuthed = claudeCodeService.hasAccess
            case .openai:     isAuthed = authManager.isOpenAIAuthenticated
            case .codexCli:   isAuthed = codexCliService.hasAccess
            case .cursor:     isAuthed = cursorService.hasAccess
            }
            if isAuthed {
                newMetrics[service] = cachedMetric
            }
        }

        metrics = newMetrics
        saveCachedData()
        sharedStore.saveMetrics(newMetrics)
        isLoading = false
    }

    func refresh(service: ServiceType) async {
        isLoading = true
        lastError = nil

        do {
            let newMetrics: UsageMetrics

            switch service {
            case .claude:
                guard authManager.isClaudeAuthenticated else {
                    throw ServiceError.notAuthenticated
                }
                newMetrics = try await claudeService.fetchUsageMetrics()
            case .claudeCode:
                guard claudeCodeService.hasAccess else {
                    throw ServiceError.notAuthenticated
                }
                do {
                    newMetrics = try await claudeCodeService.fetchUsageMetrics()
                } catch {
                    if !isAuthFailure(error), let cachedMetric = metrics[service] {
                        newMetrics = cachedMetric
                        lastError = error
                    } else {
                        throw error
                    }
                }
            case .openai:
                guard authManager.isOpenAIAuthenticated else {
                    throw ServiceError.notAuthenticated
                }
                newMetrics = try await openaiService.fetchUsageMetrics()
            case .codexCli:
                guard codexCliService.hasAccess else {
                    throw ServiceError.notAuthenticated
                }
                do {
                    newMetrics = try await codexCliService.fetchUsageMetrics()
                } catch {
                    if !isAuthFailure(error), let cachedMetric = metrics[service] {
                        newMetrics = cachedMetric
                        lastError = error
                    } else {
                        throw error
                    }
                }
            case .cursor:
                guard cursorService.hasAccess else {
                    throw ServiceError.notAuthenticated
                }
                do {
                    newMetrics = try await cursorService.fetchUsageMetrics()
                } catch {
                    if !isAuthFailure(error), let cachedMetric = metrics[service] {
                        newMetrics = cachedMetric
                        lastError = error
                    } else {
                        throw error
                    }
                }
            }

            metrics[service] = newMetrics
            saveCachedData()
            sharedStore.saveMetrics(metrics)
        } catch {
            if lastError == nil {
                lastError = error
            }
            // On auth failure, drop the section so the widget reflects reality.
            // On any other failure, fall back to the last good cache.
            if isAuthFailure(error) {
                metrics[service] = nil
                saveCachedData()
                sharedStore.saveMetrics(metrics)
            } else if metrics[service] == nil,
                      let cachedData = loadCachedMetricsFromDisk()[service] {
                metrics[service] = cachedData
            }
        }

        isLoading = false
    }

    /// Treat a 401 / `.notAuthenticated` as an auth failure. Distinguishing this
    /// from transient errors lets us drop the cached metrics so the widget
    /// stops rendering a stale section after an OAuth token expires.
    private func isAuthFailure(_ error: Error) -> Bool {
        if let serviceError = error as? ServiceError, case .notAuthenticated = serviceError {
            return true
        }
        return false
    }

    private func loadCachedData() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let decoded = try? JSONDecoder().decode([String: UsageMetrics].self, from: data) else {
            return
        }

        metrics = decoded.reduce(into: [ServiceType: UsageMetrics]()) { result, pair in
            if let service = ServiceType(rawValue: pair.key) {
                result[service] = pair.value
            }
        }
    }
    
    /// Load cached metrics from disk without modifying instance state
    private func loadCachedMetricsFromDisk() -> [ServiceType: UsageMetrics] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let decoded = try? JSONDecoder().decode([String: UsageMetrics].self, from: data) else {
            return [:]
        }

        return decoded.reduce(into: [ServiceType: UsageMetrics]()) { result, pair in
            if let service = ServiceType(rawValue: pair.key) {
                result[service] = pair.value
            }
        }
    }

    private func saveCachedData() {
        let encoded = metrics.reduce(into: [String: UsageMetrics]()) { result, pair in
            result[pair.key.rawValue] = pair.value
        }

        if let data = try? JSONEncoder().encode(encoded) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    private func setupAutoRefresh() {
        // Cancel existing timer
        refreshTimer?.invalidate()
        refreshTimer = nil

        // Don't schedule if manual refresh only
        guard refreshInterval != .manual else { return }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval.seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshAll()
            }
        }
    }

    func getNextRefreshTime() -> Date? {
        // Find the earliest reset time across all metrics
        let resetTimes = metrics.values.compactMap { metric -> Date? in
            metric.limits.compactMap { $0.resetTime }.min()
        }
        return resetTimes.min()
    }
}
