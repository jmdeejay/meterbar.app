import Foundation
import AppKit
import Combine
import Security

/// Service for fetching Claude Code usage data from `https://api.anthropic.com/api/oauth/usage`.
///
/// Steady-state fetches resolve credentials from `~/.claude/.credentials.json`. The macOS
/// Keychain item `Claude Code-credentials` is consulted on two paths:
///   1. User-initiated, via `importCredentialsFromKeychain()` — first call triggers the
///      cross-app consent prompt.
///   2. Automatic, via `reimportFromKeychainIfNeeded(...)` — when the file's access token
///      is within 60s of expiry, or on a 401 from the usage endpoint. We mirror the
///      keychain blob into the file only if the keychain's `expiresAt` is strictly newer.
///
/// The automatic path was originally avoided (see prior versions / issue #14) to dodge
/// implicit cross-app keychain reads on every fetch. We accept it now because (a) it's
/// gated on near-expiry so the read rate is ~1/8h not per-tick, and (b) once the user has
/// picked "Always Allow" on the initial Import, subsequent reads are silent. Letting Claude
/// Code own the OAuth refresh ceremony (rather than racing it from MeterBar) is what keeps
/// both clients' sessions alive at the same time.
class ClaudeCodeLocalService: ObservableObject {
    static let shared = ClaudeCodeLocalService()

    // Working endpoint (discovered via testing)
    private let usageEndpoint = "https://api.anthropic.com/api/oauth/usage"

    private let urlSession: URLSession
    private let homeDirectory: String
    private let keychainReaderOverride: (() -> Result<Data, ServiceError>)?

    @Published private(set) var hasAccess: Bool = false
    @Published private(set) var subscriptionType: String?
    @Published private(set) var rateLimitTier: String?
    @Published private(set) var lastError: ServiceError?

    private init() {
        self.homeDirectory = RealHome.path
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30.0
        configuration.timeoutIntervalForResource = 60.0
        configuration.waitsForConnectivity = true
        self.urlSession = URLSession(configuration: configuration)
        self.keychainReaderOverride = nil
        applySnapshot(currentSnapshot())
    }

    init(
        homeDirectory: String,
        urlSession: URLSession,
        keychainReader: (() -> Result<Data, ServiceError>)? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.urlSession = urlSession
        self.keychainReaderOverride = keychainReader
        applySnapshot(currentSnapshot())
    }

    // MARK: - Local Credential Resolution

    private func getRealHomeDirectory() -> String { homeDirectory }

    /// Pure: read `~/.claude/` and return a credential snapshot (or nil if none of the local
    /// files can supply a bearer token). Does not mutate published state.
    private func currentSnapshot() -> ClaudeCodeCredentialSnapshot? {
        return ClaudeCodeCredentialResolver.resolveSnapshot(homeDirectory: getRealHomeDirectory())
    }

    /// Apply a snapshot to the published auth state. Pass `nil` to clear.
    private func applySnapshot(_ snapshot: ClaudeCodeCredentialSnapshot?) {
        if let snapshot = snapshot {
            hasAccess = true
            subscriptionType = snapshot.subscriptionType
            rateLimitTier = snapshot.rateLimitTier
        } else {
            hasAccess = false
            subscriptionType = nil
            rateLimitTier = nil
        }
    }

    /// Re-read local credentials and update access state. When no token-bearing source is
    /// available, all auth-related published fields are cleared (failure-closed).
    func checkAccess() {
        applySnapshot(currentSnapshot())
    }

    // MARK: - Keychain Bridge

    /// Authoritative source of fresh credentials. Claude Code's CLI owns the
    /// OAuth refresh ceremony — it writes new tokens to its Keychain entry
    /// every time it runs and the access token is near expiry. MeterBar mirrors
    /// that entry into `~/.claude/.credentials.json` and reads from there for
    /// regular fetches, falling back to the Keychain only when the file copy
    /// has gone stale (and even then, only if the Keychain has actually
    /// progressed past the file's `expiresAt`).
    private func readKeychainBlob() -> Result<Data, ServiceError> {
        if let override = keychainReaderOverride { return override() }
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  "Claude Code-credentials",
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne,
        ]

        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                return .failure(.apiError("Unexpected keychain data format."))
            }
            return .success(data)
        case errSecItemNotFound:
            return .failure(.apiError("No Claude Code credentials in Keychain. Run `claude` in Terminal to log in first."))
        case errSecUserCanceled, errSecAuthFailed:
            return .failure(.apiError("Keychain access denied. Click Allow on the prompt and try again."))
        default:
            return .failure(.apiError("Keychain error \(status)"))
        }
    }

    @discardableResult
    func importCredentialsFromKeychain() -> Result<Void, ServiceError> {
        let data: Data
        switch readKeychainBlob() {
        case .success(let d):
            data = d
        case .failure(let err):
            return .failure(err)
        }

        switch ClaudeCodeKeychainImport.importCredentials(
            from: data,
            homeDirectory: getRealHomeDirectory()
        ) {
        case .success:
            checkAccess()
            return .success(())
        case .failure(.unexpectedFormat):
            return .failure(.apiError("Unexpected keychain data format."))
        case .failure(.writeFailed(let filePath, let message)):
            return .failure(.apiError("Could not write \(filePath): \(message)"))
        }
    }

    // MARK: - Automatic Keychain Re-import

    /// Window before expiry within which we'll proactively re-read the keychain
    /// rather than letting the next fetch trip on a stale access token.
    private let proactiveRefreshLeeway: TimeInterval = 60
    private func reimportFromKeychainIfNeeded(_ snapshot: ClaudeCodeCredentialSnapshot, force: Bool = false) async -> ClaudeCodeCredentialSnapshot? {
        if !force {
            if let expiresAt = snapshot.expiresAt,
               expiresAt.timeIntervalSinceNow > proactiveRefreshLeeway {
                return snapshot
            }
        }

        let keychainData: Data
        switch readKeychainBlob() {
        case .success(let d): keychainData = d
        case .failure:        return nil
        }

        guard let keychainSnapshot = ClaudeCodeCredentialResolver.parseCredentialsFile(data: keychainData) else {
            return nil
        }

        // Only mirror when the keychain has actually moved past our file otherwise we'd loop forever using the same expired token.
        let isFresher: Bool
        switch (keychainSnapshot.expiresAt, snapshot.expiresAt) {
        case (.some(let kc), .some(let f)): isFresher = kc > f
        case (.some, .none):                isFresher = true
        case (.none, _):                    isFresher = false
        }
        if !isFresher { return nil }

        _ = ClaudeCodeKeychainImport.importCredentials(
            from: keychainData,
            homeDirectory: getRealHomeDirectory()
        )
        return currentSnapshot() ?? keychainSnapshot
    }

    // MARK: - Usage Fetching

    func fetchUsageMetrics() async throws -> UsageMetrics {
        guard let initialSnapshot = currentSnapshot() else {
            let error = ServiceError.notAuthenticated
            await MainActor.run {
                self.applySnapshot(nil)
                self.lastError = error
            }
            throw error
        }

        // Proactive re-import — if our cached access token is about to expire
        guard let snapshot = await reimportFromKeychainIfNeeded(initialSnapshot) else {
            await MainActor.run {
                self.applySnapshot(nil)
                self.lastError = ServiceError.notAuthenticated
            }
            throw ServiceError.notAuthenticated
        }

        await MainActor.run {
            self.applySnapshot(snapshot)
        }

        return try await performUsageRequest(snapshot: snapshot, allowRefreshRetry: true)
    }

    private func performUsageRequest(snapshot: ClaudeCodeCredentialSnapshot, allowRefreshRetry: Bool) async throws -> UsageMetrics {
        guard let url = URL(string: usageEndpoint) else {
            throw ServiceError.apiError("Invalid usage endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(snapshot.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 30.0

        do {
            let (data, response) = try await urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ServiceError.apiError("Invalid response type")
            }

            if httpResponse.statusCode == 401 {
                // Reactive re-import: the proactive path may have skipped (no expiresAt) or the token died earlier than the stamp claimed.
                // Force a keychain check and retry once.
                if allowRefreshRetry, let refreshed = await reimportFromKeychainIfNeeded(snapshot, force: true) {
                    await MainActor.run { self.applySnapshot(refreshed) }
                    return try await performUsageRequest(snapshot: refreshed, allowRefreshRetry: false)
                }
                await MainActor.run {
                    self.applySnapshot(nil)
                    self.lastError = ServiceError.notAuthenticated
                }
                throw ServiceError.notAuthenticated
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw ServiceError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let usageResponse = try decoder.decode(ClaudeCodeUsageResponse.self, from: data)

            await MainActor.run {
                self.lastError = nil
            }

            let sessionLimit = UsageLimit(
                compactLabel: "S",
                verboseLabel: "Session (5h)",
                used: usageResponse.fiveHour.utilization,
                total: 100.0,
                resetTime: usageResponse.fiveHour.resetsAt
            )

            let weeklyLimit = UsageLimit(
                compactLabel: "W",
                verboseLabel: "All Models (7d)",
                used: usageResponse.sevenDay.utilization,
                total: 100.0,
                resetTime: usageResponse.sevenDay.resetsAt
            )

            var limits: [UsageLimit] = [sessionLimit, weeklyLimit]
            if let sonnet = usageResponse.sevenDaySonnet {
                limits.append(UsageLimit(
                    compactLabel: "Sn",
                    verboseLabel: "Sonnet (7d)",
                    used: sonnet.utilization,
                    total: 100.0,
                    resetTime: sonnet.resetsAt
                ))
            }

            return UsageMetrics(service: .claudeCode, limits: limits)
        } catch let urlError as URLError {
            let errorMessage: String
            switch urlError.code {
            case .notConnectedToInternet:
                errorMessage = "No internet connection"
            case .cannotFindHost, .dnsLookupFailed:
                errorMessage = "DNS lookup failed"
            case .timedOut:
                errorMessage = "Request timed out"
            default:
                errorMessage = urlError.localizedDescription
            }
            let error = ServiceError.apiError(errorMessage)
            await MainActor.run { self.lastError = error }
            throw error
        } catch let error as ServiceError {
            throw error
        } catch {
            let serviceError = ServiceError.parsingError
            await MainActor.run { self.lastError = serviceError }
            throw serviceError
        }
    }
}

// MARK: - Local Credential Resolver

/// Snapshot of the credentials resolved from `~/.claude/` config files.
struct ClaudeCodeCredentialSnapshot: Equatable {
    let token: String
    let refreshToken: String?
    let expiresAt: Date?
    let subscriptionType: String?
    let rateLimitTier: String?
}

/// Pure parser for Claude Code's local config files. Exposed at module-internal access so
/// `ClaudeCodeLocalServiceTests` can exercise precedence and failure-closed behavior with
/// inline fixtures and a temporary home directory.
enum ClaudeCodeCredentialResolver {
    /// Search `~/.claude/.credentials.json`, `~/.claude/.claude.json`, and `~/.claude/settings.json`
    /// in that fixed order. Tokens are sourced from `.credentials.json` first, then from
    /// `settings.json`'s `env.ANTHROPIC_AUTH_TOKEN`. Subscription metadata is taken from the
    /// credentials file when present and otherwise enriched from `.claude.json`. Returns nil
    /// when no readable source can supply a bearer token.
    static func resolveSnapshot(homeDirectory: String) -> ClaudeCodeCredentialSnapshot? {
        let claudeDir = "\(homeDirectory)/.claude"

        let credentialsSnapshot = readFile(at: "\(claudeDir)/.credentials.json")
            .flatMap(parseCredentialsFile)
        let claudeJsonMetadata = readFile(at: "\(claudeDir)/.claude.json")
            .flatMap(parseClaudeJsonMetadata)
        let settingsToken = readFile(at: "\(claudeDir)/settings.json")
            .flatMap(parseSettingsAuthToken)

        guard let token = credentialsSnapshot?.token ?? settingsToken else {
            return nil
        }

        let subscriptionType = credentialsSnapshot?.subscriptionType
            ?? claudeJsonMetadata?.subscriptionType
        let rateLimitTier = credentialsSnapshot?.rateLimitTier
            ?? claudeJsonMetadata?.rateLimitTier

        return ClaudeCodeCredentialSnapshot(
            token: token,
            refreshToken: credentialsSnapshot?.refreshToken,
            expiresAt: credentialsSnapshot?.expiresAt,
            subscriptionType: subscriptionType,
            rateLimitTier: rateLimitTier
        )
    }

    /// Decode `~/.claude/.credentials.json`. Expected shape mirrors what Claude Code writes
    /// on platforms without a system Keychain: a `claudeAiOauth` object with `accessToken`,
    /// the long-lived `refreshToken`, an `expiresAt` epoch-millis stamp, and optional
    /// `subscriptionType` / `rateLimitTier` metadata.
    static func parseCredentialsFile(data: Data) -> ClaudeCodeCredentialSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            return nil
        }
        let refreshToken = (oauth["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let expiresAt: Date? = {
            if let ms = oauth["expiresAt"] as? Double {
                return Date(timeIntervalSince1970: ms / 1000.0)
            }
            return nil
        }()
        return ClaudeCodeCredentialSnapshot(
            token: token,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        )
    }

    /// Extract subscription metadata from `~/.claude/.claude.json`. Tolerates the field living
    /// either under an `oauthAccount` object or at the top level.
    static func parseClaudeJsonMetadata(data: Data) -> (subscriptionType: String?, rateLimitTier: String?)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let oauthAccount = object["oauthAccount"] as? [String: Any]
        let subscription = (oauthAccount?["subscriptionType"] as? String)
            ?? (object["subscriptionType"] as? String)
        let tier = (oauthAccount?["rateLimitTier"] as? String)
            ?? (object["rateLimitTier"] as? String)
        if subscription == nil && tier == nil {
            return nil
        }
        return (subscriptionType: subscription, rateLimitTier: tier)
    }

    /// Extract a bearer token override from `~/.claude/settings.json`'s `env.ANTHROPIC_AUTH_TOKEN`,
    /// matching the standard env-var that Claude Code honors at runtime.
    static func parseSettingsAuthToken(data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = object["env"] as? [String: Any],
              let token = env["ANTHROPIC_AUTH_TOKEN"] as? String,
              !token.isEmpty else {
            return nil
        }
        return token
    }

    private static func readFile(at path: String) -> Data? {
        return FileManager.default.contents(atPath: path)
    }
}

// MARK: - Response Models

struct ClaudeCodeUsageResponse: Codable {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow
    let sevenDaySonnet: UsageWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
    }
}

struct UsageWindow: Codable {
    let utilization: Double
    let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}
