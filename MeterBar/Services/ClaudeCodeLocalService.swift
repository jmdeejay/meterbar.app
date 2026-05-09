import Foundation
import AppKit
import Combine
import Security

/// Service for fetching Claude Code usage data from `https://api.anthropic.com/api/oauth/usage`.
///
/// Authentication on every refresh is resolved exclusively from local files under `~/.claude/`.
/// The macOS Keychain item `Claude Code-credentials` is *only* read by the user-initiated
/// `importCredentialsFromKeychain()` bridge (see below), which copies the OAuth blob to
/// `~/.claude/.credentials.json` once and never touches the keychain again until the user
/// explicitly clicks Import again. This avoids the original problem (implicit cross-app keychain
/// reads on every fetch — incompatible with App Sandbox and lacking user consent). See issue #14.
class ClaudeCodeLocalService: ObservableObject {
    static let shared = ClaudeCodeLocalService()

    // Working endpoint (discovered via testing)
    private let usageEndpoint = "https://api.anthropic.com/api/oauth/usage"

    // URLSession with timeout configuration
    private lazy var urlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30.0
        configuration.timeoutIntervalForResource = 60.0
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    @Published private(set) var hasAccess: Bool = false
    @Published private(set) var subscriptionType: String?
    @Published private(set) var rateLimitTier: String?
    @Published private(set) var lastError: ServiceError?

    private init() {
        applySnapshot(currentSnapshot())
    }

    // MARK: - Local Credential Resolution

    /// Real user home directory — `getpwuid(getuid())` returns the actual home even when the
    /// process is sandboxed and `FileManager.homeDirectoryForCurrentUser` would point at a
    /// container path.
    private func getRealHomeDirectory() -> String {
        if let pw = getpwuid(getuid()) {
            return String(cString: pw.pointee.pw_dir)
        }
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            return home
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

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

    // MARK: - One-time Keychain Import

    /// User-initiated bridge for users whose Claude Code build only writes its OAuth token
    /// to the macOS Keychain (the default on macOS). Reads the keychain blob ONCE — only
    /// when this method is called from an explicit UI action — and writes it verbatim to
    /// `~/.claude/.credentials.json`. The rest of the service continues to read from the
    /// file path; the keychain is never consulted again until the user clicks Import once
    /// more (e.g. after a token rotation). The first call triggers macOS's standard
    /// cross-app keychain consent prompt.
    @discardableResult
    func importCredentialsFromKeychain() -> Result<Void, ServiceError> {
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
            break
        case errSecItemNotFound:
            return .failure(.apiError("No Claude Code credentials in Keychain. Run `claude` in Terminal to log in first."))
        case errSecUserCanceled, errSecAuthFailed:
            return .failure(.apiError("Keychain access denied. Click Allow on the prompt and try again."))
        default:
            return .failure(.apiError("Keychain error \(status)"))
        }

        guard let data = item as? Data else {
            return .failure(.apiError("Unexpected keychain data format."))
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

    // MARK: - Usage Fetching

    func fetchUsageMetrics() async throws -> UsageMetrics {
        let snapshot = currentSnapshot()

        guard let snapshot = snapshot else {
            let error = ServiceError.notAuthenticated
            await MainActor.run {
                self.applySnapshot(nil)
                self.lastError = error
            }
            throw error
        }

        await MainActor.run {
            self.applySnapshot(snapshot)
        }

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

            // Session limit = 5-hour window
            let sessionLimit = UsageLimit(
                used: usageResponse.fiveHour.utilization,
                total: 100.0,
                resetTime: usageResponse.fiveHour.resetsAt
            )

            // Weekly limit = 7-day window (all models)
            let weeklyLimit = UsageLimit(
                used: usageResponse.sevenDay.utilization,
                total: 100.0,
                resetTime: usageResponse.sevenDay.resetsAt
            )

            // Sonnet-only weekly limit (if available)
            var sonnetLimit: UsageLimit? = nil
            if let sonnet = usageResponse.sevenDaySonnet {
                sonnetLimit = UsageLimit(
                    used: sonnet.utilization,
                    total: 100.0,
                    resetTime: sonnet.resetsAt
                )
            }

            return UsageMetrics(
                service: .claudeCode,
                sessionLimit: sessionLimit,
                weeklyLimit: weeklyLimit,
                codeReviewLimit: sonnetLimit
            )
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
            subscriptionType: subscriptionType,
            rateLimitTier: rateLimitTier
        )
    }

    /// Decode `~/.claude/.credentials.json`. Expected shape mirrors what Claude Code writes
    /// on platforms without a system Keychain: a `claudeAiOauth` object with `accessToken`
    /// and optional `subscriptionType` / `rateLimitTier` metadata.
    static func parseCredentialsFile(data: Data) -> ClaudeCodeCredentialSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            return nil
        }
        return ClaudeCodeCredentialSnapshot(
            token: token,
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
