#!/usr/bin/env swift
//
// APIAccessTest.swift
// MeterBar
//
// Standalone script that mirrors what the running app does to fetch usage data,
// without going through the sandbox. Five tests, in display order:
//
//   1. Claude Code   — OAuth from ~/.claude/.credentials.json (Keychain fallback)
//   2. Claude API    — Admin API key from app's Keychain
//   3. OpenAI Codex  — OAuth from ~/.codex/auth.json
//   4. OpenAI API    — Admin API key from app's Keychain
//   5. Cursor        — Local SQLite + cookie auth
//
// Run with: swift scripts/APIAccessTest.swift
//

import Foundation
import Security
import SQLite3

// MARK: - Shared helpers

func printHeader(_ title: String, emoji: String) {
    print("\n" + String(repeating: "=", count: 60))
    print("\(emoji) \(title)")
    print(String(repeating: "=", count: 60))
}

func formatPercent(_ value: Double) -> String { String(format: "%.1f%%", value) }

func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

func realHomeDirectory() -> String {
    if let pw = getpwuid(getuid()) {
        return String(cString: pw.pointee.pw_dir)
    }
    return ProcessInfo.processInfo.environment["HOME"]
        ?? FileManager.default.homeDirectoryForCurrentUser.path
}

/// Read a generic-password keychain item by service (and optional account).
/// Used for the Claude Code system Keychain entry.
func readKeychainData(service: String, account: String? = nil) -> Data? {
    var query: [String: Any] = [
        kSecClass as String:       kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecReturnData as String:  true,
        kSecMatchLimit as String:  kSecMatchLimitOne
    ]
    if let account = account { query[kSecAttrAccount as String] = account }

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else { return nil }
    return data
}

/// Read an Admin API key stored by the MeterBar app under its keychain service.
func readMeterBarAdminKey(account: String) -> String? {
    guard let data = readKeychainData(service: "com.jmdeejay.meterbar", account: account) else {
        return nil
    }
    return String(data: data, encoding: .utf8)
}

// MARK: - 1. Claude Code (OAuth subscription)

struct ClaudeCodeUsageResponse: Decodable {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow
    let sevenDaySonnet: UsageWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
    }
}

struct UsageWindow: Decodable {
    let utilization: Double
    let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct ClaudeCodeSnapshot {
    let token: String
    let subscriptionType: String?
    let rateLimitTier: String?
    let source: String
}

func parseClaudeCodeCredentials(_ data: Data, source: String) -> ClaudeCodeSnapshot? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = object["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String,
          !token.isEmpty else { return nil }
    return ClaudeCodeSnapshot(
        token: token,
        subscriptionType: oauth["subscriptionType"] as? String,
        rateLimitTier: oauth["rateLimitTier"] as? String,
        source: source
    )
}

func resolveClaudeCodeSnapshot() -> ClaudeCodeSnapshot? {
    let credentialsPath = "\(realHomeDirectory())/.claude/.credentials.json"
    if let data = FileManager.default.contents(atPath: credentialsPath),
       let snapshot = parseClaudeCodeCredentials(data, source: "~/.claude/.credentials.json") {
        return snapshot
    }
    if let data = readKeychainData(service: "Claude Code-credentials"),
       let snapshot = parseClaudeCodeCredentials(data, source: "Keychain (Claude Code-credentials)") {
        return snapshot
    }
    return nil
}

func testClaudeCode() async -> (Bool, String) {
    printHeader("CLAUDE CODE (OAuth subscription)", emoji: "🟣")

    guard let snapshot = resolveClaudeCodeSnapshot() else {
        print("⚠️  SKIPPED: No Claude Code OAuth token found")
        print("   File checked: ~/.claude/.credentials.json")
        print("   Keychain checked: Claude Code-credentials")
        print("   To configure: run `claude` in Terminal to log in")
        return (false, "Not configured")
    }

    print("✓ Source: \(snapshot.source)")
    if let sub = snapshot.subscriptionType { print("  Subscription: \(sub)") }
    if let tier = snapshot.rateLimitTier { print("  Rate-limit tier: \(tier)") }

    guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
        return (false, "Invalid URL")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(snapshot.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.timeoutInterval = 30

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return (false, "Invalid response") }

        if http.statusCode == 401 {
            print("❌ Authentication failed (401) — token expired; run `claude` to refresh")
            return (false, "Authentication failed")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown"
            print("❌ HTTP \(http.statusCode): \(body.prefix(120))")
            return (false, "HTTP \(http.statusCode)")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let usage = try decoder.decode(ClaudeCodeUsageResponse.self, from: data)

        print("✅ SUCCESS: Claude Code OAuth usage endpoint reachable")
        print("\nUsage:")
        print("  Session (5h):     \(formatPercent(usage.fiveHour.utilization))" +
              (usage.fiveHour.resetsAt.map { " — resets \(formatDate($0))" } ?? ""))
        print("  All Models (7d):  \(formatPercent(usage.sevenDay.utilization))" +
              (usage.sevenDay.resetsAt.map { " — resets \(formatDate($0))" } ?? ""))
        if let sonnet = usage.sevenDaySonnet {
            print("  Sonnet (7d):      \(formatPercent(sonnet.utilization))" +
                  (sonnet.resetsAt.map { " — resets \(formatDate($0))" } ?? ""))
        }
        return (true, "\(formatPercent(usage.sevenDay.utilization)) weekly")
    } catch {
        print("❌ Request failed: \(error.localizedDescription)")
        return (false, error.localizedDescription)
    }
}

// MARK: - 2. Claude API (Admin)

struct AnthropicUsageResponse: Decodable {
    let data: [AnthropicUsageBucket]
}

struct AnthropicUsageBucket: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

func testClaudeAPI() async -> (Bool, String) {
    printHeader("CLAUDE API (Admin)", emoji: "🔵")

    guard let adminKey = readMeterBarAdminKey(account: "claude_admin_key") else {
        print("⚠️  SKIPPED: No Claude Admin API key in keychain")
        print("   To configure: add it in MeterBar → Settings → Claude (Anthropic)")
        return (false, "Not configured")
    }
    print("✓ Admin key found in keychain")

    let endDate = Date()
    let startDate = Calendar.current.date(byAdding: .day, value: -7, to: endDate)!
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]

    var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/usage_report/messages")!
    components.queryItems = [
        URLQueryItem(name: "starting_at", value: iso.string(from: startDate)),
        URLQueryItem(name: "ending_at", value: iso.string(from: endDate)),
        URLQueryItem(name: "bucket_width", value: "1d"),
        URLQueryItem(name: "group_by[]", value: "model")
    ]
    guard let url = components.url else { return (false, "Invalid URL") }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue(adminKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 30

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return (false, "Invalid response") }

        if http.statusCode == 401 {
            print("❌ Authentication failed (401) — Admin key invalid or expired")
            return (false, "Authentication failed")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown"
            print("❌ HTTP \(http.statusCode): \(body.prefix(120))")
            return (false, "HTTP \(http.statusCode)")
        }

        let usage = try JSONDecoder().decode(AnthropicUsageResponse.self, from: data)
        let totalTokens = usage.data.reduce(0) { $0 + ($1.inputTokens ?? 0) + ($1.outputTokens ?? 0) }
        print("✅ SUCCESS: Claude Admin API reachable")
        print("\nUsage (last 7 days):")
        print("  Total tokens: \(totalTokens)")
        print("  Buckets:      \(usage.data.count)")
        return (true, "\(totalTokens) tokens")
    } catch {
        print("❌ Request failed: \(error.localizedDescription)")
        return (false, error.localizedDescription)
    }
}

// MARK: - 3. OpenAI Codex (OAuth subscription)

struct CodexAuthFile: Decodable {
    let tokens: CodexTokens?
}

struct CodexTokens: Decodable {
    let accessToken: String?
    let accountId: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case accountId   = "account_id"
    }
}

struct CodexCliUsageResponse: Decodable {
    let planType: String
    let rateLimit: CodexRateLimit?
    let codeReviewRateLimit: CodexRateLimit?

    enum CodingKeys: String, CodingKey {
        case planType            = "plan_type"
        case rateLimit           = "rate_limit"
        case codeReviewRateLimit = "code_review_rate_limit"
    }
}

struct CodexRateLimit: Decodable {
    let primaryWindow: CodexLimitWindow
    let secondaryWindow: CodexLimitWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow   = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

struct CodexLimitWindow: Decodable {
    let usedPercent: Double
    let resetAt: Int64

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt     = "reset_at"
    }
}

func testCodexCli() async -> (Bool, String) {
    printHeader("OPENAI CODEX (OAuth subscription)", emoji: "🟢")

    let authPath = "\(realHomeDirectory())/.codex/auth.json"
    guard let data = FileManager.default.contents(atPath: authPath),
          let auth = try? JSONDecoder().decode(CodexAuthFile.self, from: data),
          let token = auth.tokens?.accessToken, !token.isEmpty else {
        print("⚠️  SKIPPED: No Codex CLI OAuth token at \(authPath)")
        print("   To configure: run `codex login` in Terminal")
        return (false, "Not configured")
    }
    print("✓ Source: ~/.codex/auth.json")
    if let accountId = auth.tokens?.accountId {
        print("  Account ID: \(accountId)")
    } else {
        print("  No account_id — request will return free-plan data")
    }

    guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
        return (false, "Invalid URL")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let accountId = auth.tokens?.accountId {
        request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
    }
    request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
    request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
    request.setValue("*/*", forHTTPHeaderField: "Accept")
    request.setValue(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        forHTTPHeaderField: "User-Agent"
    )
    request.timeoutInterval = 30

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return (false, "Invalid response") }

        if http.statusCode == 401 {
            print("❌ Authentication failed (401) — token expired; run `codex login` again")
            return (false, "Authentication failed")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown"
            print("❌ HTTP \(http.statusCode): \(body.prefix(120))")
            return (false, "HTTP \(http.statusCode)")
        }

        let usage = try JSONDecoder().decode(CodexCliUsageResponse.self, from: data)
        print("✅ SUCCESS: Codex CLI usage endpoint reachable")
        print("\nPlan: \(usage.planType)")
        if let rate = usage.rateLimit {
            let p = rate.primaryWindow
            print("  Session (5h):  \(formatPercent(p.usedPercent)) — resets \(formatDate(Date(timeIntervalSince1970: TimeInterval(p.resetAt))))")
            if let s = rate.secondaryWindow {
                print("  Weekly (7d):   \(formatPercent(s.usedPercent)) — resets \(formatDate(Date(timeIntervalSince1970: TimeInterval(s.resetAt))))")
            } else {
                print("  Weekly (7d):   \(formatPercent(0.0))")
            }
        } else {
            print("  No rate_limit (free plan or zero usage)")
        }
        if let cr = usage.codeReviewRateLimit?.primaryWindow {
            print("  Code Review:   \(formatPercent(cr.usedPercent)) — resets \(formatDate(Date(timeIntervalSince1970: TimeInterval(cr.resetAt))))")
        }
        let weekly = usage.rateLimit?.secondaryWindow?.usedPercent ?? 0
        return (true, "\(usage.planType), \(formatPercent(weekly)) weekly")
    } catch {
        print("❌ Request failed: \(error.localizedDescription)")
        return (false, error.localizedDescription)
    }
}

// MARK: - 4. OpenAI API (Admin)

struct OpenAIUsageResponse: Decodable {
    let data: [OpenAIUsageBucket]
}

struct OpenAIUsageBucket: Decodable {
    let results: [OpenAIUsageResult]
}

struct OpenAIUsageResult: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

func testOpenAIAPI() async -> (Bool, String) {
    printHeader("OPENAI API (Admin)", emoji: "🟢")

    guard let adminKey = readMeterBarAdminKey(account: "openai_admin_key") else {
        print("⚠️  SKIPPED: No OpenAI Admin API key in keychain")
        print("   To configure: add it in MeterBar → Settings → OpenAI")
        return (false, "Not configured")
    }
    print("✓ Admin key found in keychain")

    let endDate = Date()
    let startDate = Calendar.current.date(byAdding: .day, value: -7, to: endDate)!

    var components = URLComponents(string: "https://api.openai.com/v1/organization/usage/completions")!
    components.queryItems = [
        URLQueryItem(name: "start_time", value: String(Int(startDate.timeIntervalSince1970))),
        URLQueryItem(name: "end_time",   value: String(Int(endDate.timeIntervalSince1970))),
        URLQueryItem(name: "bucket_width", value: "1d"),
        URLQueryItem(name: "group_by", value: "model")
    ]
    guard let url = components.url else { return (false, "Invalid URL") }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(adminKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 30

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return (false, "Invalid response") }

        if http.statusCode == 401 {
            print("❌ Authentication failed (401) — Admin key invalid or expired")
            return (false, "Authentication failed")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown"
            print("❌ HTTP \(http.statusCode): \(body.prefix(120))")
            return (false, "HTTP \(http.statusCode)")
        }

        let usage = try JSONDecoder().decode(OpenAIUsageResponse.self, from: data)
        let totalTokens = usage.data
            .flatMap { $0.results }
            .reduce(0) { $0 + ($1.inputTokens ?? 0) + ($1.outputTokens ?? 0) }
        print("✅ SUCCESS: OpenAI Admin API reachable")
        print("\nUsage (last 7 days):")
        print("  Total tokens: \(totalTokens)")
        print("  Buckets:      \(usage.data.count)")
        return (true, "\(totalTokens) tokens")
    } catch {
        print("❌ Request failed: \(error.localizedDescription)")
        return (false, error.localizedDescription)
    }
}

// MARK: - 5. Cursor

struct CursorUsageSummaryResponse: Decodable {
    let billingCycleEnd: String?
    let membershipType: String?
    let individualUsage: CursorIndividualUsage?
}

struct CursorIndividualUsage: Decodable {
    let plan: CursorPlanUsage?
    let onDemand: CursorOnDemandUsage?
}

struct CursorPlanUsage: Decodable {
    let totalPercentUsed: Double?
    let autoPercentUsed: Double?
    let apiPercentUsed: Double?
}

struct CursorOnDemandUsage: Decodable {
    let used: Int?
    let limit: Int?
    let enabled: Bool?
}

func cursorDatabasePath() -> String? {
    let home = realHomeDirectory()
    let candidates = [
        "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb",
        "\(home)/Library/Application Support/Cursor/state.vscdb",
        "\(home)/.config/Cursor/User/globalStorage/state.vscdb"
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0) }
}

func extractUserIdFromJWT(_ token: String) -> String? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var payload = String(parts[1])
    let remainder = payload.count % 4
    if remainder > 0 { payload += String(repeating: "=", count: 4 - remainder) }
    payload = payload
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    guard let data = Data(base64Encoded: payload),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sub = json["sub"] as? String else { return nil }
    return sub.contains("|") ? sub.components(separatedBy: "|").last : sub
}

func cursorTokenFromDatabase() -> (userId: String, token: String)? {
    guard let dbPath = cursorDatabasePath() else {
        print("  Database not found at any known path")
        return nil
    }
    print("  Database: \(dbPath)")

    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        print("  Failed to open database")
        sqlite3_close(db)
        return nil
    }
    defer { sqlite3_close(db) }

    var statement: OpaquePointer?
    let query = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'"
    guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
        return nil
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
          let cString = sqlite3_column_text(statement, 0) else {
        print("  No token row in ItemTable (not logged in?)")
        return nil
    }
    let token = String(cString: cString)
    guard let userId = extractUserIdFromJWT(token) else {
        print("  Could not extract userId from JWT")
        return nil
    }
    return (userId, token)
}

func testCursor() async -> (Bool, String) {
    printHeader("CURSOR", emoji: "🟡")

    guard let (userId, token) = cursorTokenFromDatabase() else {
        print("⚠️  SKIPPED: No Cursor token found")
        print("   To configure: open Cursor and sign in")
        return (false, "Not configured")
    }
    print("✓ Token found (user \(userId.prefix(8))...)")

    guard let url = URL(string: "https://cursor.com/api/usage-summary") else {
        return (false, "Invalid URL")
    }

    let authCookie = "\(userId)%3A%3A\(token)"
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("WorkosCursorSessionToken=\(authCookie)", forHTTPHeaderField: "Cookie")
    request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
    request.setValue("https://cursor.com/dashboard?tab=usage", forHTTPHeaderField: "Referer")
    request.setValue(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
        forHTTPHeaderField: "User-Agent"
    )
    request.timeoutInterval = 30

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return (false, "Invalid response") }

        if http.statusCode == 401 {
            print("❌ Authentication failed (401) — sign out and back in to Cursor")
            return (false, "Authentication failed")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown"
            print("❌ HTTP \(http.statusCode): \(body.prefix(120))")
            return (false, "HTTP \(http.statusCode)")
        }

        let usage = try JSONDecoder().decode(CursorUsageSummaryResponse.self, from: data)
        print("✅ SUCCESS: Cursor usage-summary endpoint reachable")
        print("\nPlan: \(usage.membershipType ?? "unknown")")
        if let end = usage.billingCycleEnd { print("Billing cycle ends: \(end)") }

        let plan = usage.individualUsage?.plan
        let total = plan?.totalPercentUsed ?? 0
        let api   = plan?.apiPercentUsed ?? 0
        let auto  = plan?.autoPercentUsed ?? 0
        print("  API:     \(formatPercent(api))")
        print("  Monthly: \(formatPercent(total)) (auto \(formatPercent(auto)))")

        if let onDemand = usage.individualUsage?.onDemand, onDemand.enabled == true {
            let used = onDemand.used ?? 0
            let cap  = onDemand.limit ?? 0
            print("  On-Demand: \(used)\(cap > 0 ? " / \(cap)" : "")")
        }
        return (true, "\(usage.membershipType ?? "unknown") plan, \(formatPercent(total)) monthly")
    } catch {
        print("❌ Request failed: \(error.localizedDescription)")
        return (false, error.localizedDescription)
    }
}

// MARK: - Main

func printSummary(_ results: [(String, Bool, String)]) {
    print("\n" + String(repeating: "=", count: 60))
    print("📊 SUMMARY")
    print(String(repeating: "=", count: 60))
    print("")
    print("  Service        | Status         | Details")
    print("  " + String(repeating: "-", count: 55))
    for (service, success, message) in results {
        let paddedService = service.padding(toLength: 13, withPad: " ", startingAt: 0)
        let status: String
        if success { status = "✅ Connected" }
        else if message == "Not configured" { status = "⚪ Skip" }
        else { status = "❌ Failed" }
        let paddedStatus = status.padding(toLength: 14, withPad: " ", startingAt: 0)
        print("  \(paddedService) | \(paddedStatus) | \(message)")
    }
    print("")
}

print("")
print("╔══════════════════════════════════════════════════════════╗")
print("║              MeterBar API Access Test Suite              ║")
print("╚══════════════════════════════════════════════════════════╝")

Task {
    var results: [(String, Bool, String)] = []

    let cc = await testClaudeCode()
    results.append(("Claude Code", cc.0, cc.1))

    let claude = await testClaudeAPI()
    results.append(("Claude API", claude.0, claude.1))

    let codex = await testCodexCli()
    results.append(("OpenAI Codex", codex.0, codex.1))

    let openai = await testOpenAIAPI()
    results.append(("OpenAI API", openai.0, openai.1))

    let cursor = await testCursor()
    results.append(("Cursor", cursor.0, cursor.1))

    printSummary(results)

    print("╔══════════════════════════════════════════════════════════╗")
    print("║                      Tests Complete                      ║")
    print("╚══════════════════════════════════════════════════════════╝")
    print("")
    exit(0)
}

RunLoop.main.run()
