import XCTest
@testable import MeterBar

@MainActor
final class UsageDataManagerTests: XCTestCase {
    // Shared stub + session: URLProtocolStub uses static state, so one stub
    // serves all five services. Routes are differentiated by URL predicates.
    private var stub: URLProtocolStub!
    private var session: URLSession!

    private var keychain: InMemoryKeychainBackend!
    private var auth: AuthenticationManager!

    private var claudeCodeHome: URL!
    private var codexHome: URL!
    /// Defaults to `nil` so Cursor reads as unauthenticated. Tests that need
    /// Cursor authed flip this and rebuild the manager via `makeManager()`.
    private var cursorAuthResult: (userId: String, token: String)?

    private var sharedStoreDir: URL!
    private var sharedStore: SharedDataStore!

    private var userDefaults: UserDefaults!
    private var userDefaultsSuite: String!

    private var manager: UsageDataManager!

    // MARK: - Setup

    override func setUpWithError() throws {
        // Avoid spinning up the 15-min auto-refresh Timer.
        // @AppStorage reads from UserDefaults.standard regardless of the
        // injected userDefaults, so we have to set it on .standard.
        UserDefaults.standard.set(RefreshInterval.manual.rawValue, forKey: "refreshInterval")

        stub = URLProtocolStub()
        session = URLProtocolStub.makeURLSession(with: stub)

        keychain = InMemoryKeychainBackend()
        auth = AuthenticationManager(keychain: keychain)

        claudeCodeHome = try makeTempDir(prefix: "claudeCode")
        try FileManager.default.createDirectory(
            at: claudeCodeHome.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )

        codexHome = try makeTempDir(prefix: "codex")
        try FileManager.default.createDirectory(
            at: codexHome.appendingPathComponent(".codex"),
            withIntermediateDirectories: true
        )

        sharedStoreDir = try makeTempDir(prefix: "sharedStore")
        sharedStore = SharedDataStore(containerURL: sharedStoreDir)

        userDefaultsSuite = "UsageDataManagerTests-\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: userDefaultsSuite)!

        manager = makeManager()
    }

    override func tearDownWithError() throws {
        // Invalidate any Timer (even though refreshInterval defaults to .manual
        // in tests, set it again to be defensive).
        manager.refreshInterval = .manual

        userDefaults.removePersistentDomain(forName: userDefaultsSuite)
        UserDefaults.standard.removeObject(forKey: "refreshInterval")

        try? FileManager.default.removeItem(at: claudeCodeHome)
        try? FileManager.default.removeItem(at: codexHome)
        try? FileManager.default.removeItem(at: sharedStoreDir)
    }

    // MARK: - refreshAll: no authentication

    func testRefreshAllWithNoAuthLeavesMetricsEmpty() async {
        XCTAssertTrue(manager.metrics.isEmpty)
        XCTAssertFalse(manager.isLoading)

        await manager.refreshAll()

        XCTAssertTrue(manager.metrics.isEmpty)
        XCTAssertFalse(manager.isLoading)
        XCTAssertTrue(stub.requests.isEmpty, "No requests should fire when nothing is authed")
    }

    // MARK: - refreshAll: happy paths

    func testRefreshAllWithClaudeApiAuthOnlyPopulatesClaudeMetric() async {
        _ = auth.setClaudeAdminKey("sk-ant-test")
        stub.respond(when: matchClaudeApi, with: Data("""
            {"data":[{"input_tokens":100,"output_tokens":50}]}
            """.utf8), status: 200)

        await manager.refreshAll()

        XCTAssertEqual(manager.metrics.count, 1)
        XCTAssertNotNil(manager.metrics[.claude])
    }

    func testRefreshAllWithAllServicesAuthedPopulatesAllFive() async throws {
        // Claude API + OpenAI API auth
        _ = auth.setClaudeAdminKey("sk-ant-test")
        _ = auth.setOpenAIAdminKey("sk-openai-test")

        // Claude Code + Codex CLI local credentials
        try writeClaudeCodeCredentials()
        try writeCodexAuth()
        cursorAuthResult = ("user-1", "tok-1")

        // Rebuild manager so the services see the new credential files +
        // populated Cursor auth resolver.
        manager = makeManager()

        stub.respond(when: matchClaudeApi, with: Data("{\"data\":[]}".utf8), status: 200)
        stub.respond(when: matchClaudeCodeUsage, with: Data("""
            {"five_hour":{"utilization":10},"seven_day":{"utilization":20}}
            """.utf8), status: 200)
        stub.respond(when: matchOpenAIUsage, with: Data("{\"data\":[]}".utf8), status: 200)
        stub.respond(when: matchCodexUsage, with: Data("""
            {"plan_type":"free","rate_limit":null,"code_review_rate_limit":null,"credits":null}
            """.utf8), status: 200)
        stub.respond(when: matchCursorUsage, with: Data("""
            {"membershipType":"pro","individualUsage":{"plan":{"totalPercentUsed":5,"autoPercentUsed":0,"apiPercentUsed":5},"onDemand":{"enabled":false}}}
            """.utf8), status: 200)

        await manager.refreshAll()

        XCTAssertEqual(manager.metrics.count, 5)
        XCTAssertNotNil(manager.metrics[.claude])
        XCTAssertNotNil(manager.metrics[.claudeCode])
        XCTAssertNotNil(manager.metrics[.openai])
        XCTAssertNotNil(manager.metrics[.codexCli])
        XCTAssertNotNil(manager.metrics[.cursor])
    }

    // MARK: - refreshAll: auth failure drops the section

    func testRefreshAllOn401ForClaudeCodeDropsThatSection() async throws {
        try writeClaudeCodeCredentials()
        manager = makeManager()

        // Pre-populate cache for claudeCode so we can verify the drop.
        manager.metrics[.claudeCode] = UsageMetrics(service: .claudeCode, limits: [
            UsageLimit(compactLabel: "S", verboseLabel: "Session", used: 30, total: 100)
        ])

        stub.respond(when: matchClaudeCodeUsage, with: Data(), status: 401)

        await manager.refreshAll()

        XCTAssertNil(manager.metrics[.claudeCode], "401 should drop the cached section")
    }

    // MARK: - refreshAll: transient failure preserves cache

    func testRefreshAllOn500ForCursorPreservesCachedSection() async {
        // Cursor must be authed for the catch-then-preserve-cache path to fire;
        // an un-authed service is dropped instead.
        cursorAuthResult = ("user-1", "tok-1")
        manager = makeManager()

        let cached = UsageMetrics(service: .cursor, limits: [
            UsageLimit(compactLabel: "M", verboseLabel: "Monthly", used: 30, total: 100)
        ])
        manager.metrics[.cursor] = cached

        stub.respond(when: matchCursorUsage, with: Data("oops".utf8), status: 500)

        await manager.refreshAll()

        XCTAssertNotNil(manager.metrics[.cursor], "Transient 500 should preserve cache")
        XCTAssertEqual(manager.metrics[.cursor]?.limits.first?.used, 30)
    }

    // MARK: - refreshAll: de-authed service has cache dropped

    func testRefreshAllDropsCachedSectionForNoLongerAuthenticatedService() async {
        // Pre-populate a Claude API cache.
        let cached = UsageMetrics(service: .claude, limits: [
            UsageLimit(compactLabel: "W", verboseLabel: "Weekly", used: 1000, total: 10000)
        ])
        manager.metrics[.claude] = cached
        XCTAssertNotNil(manager.metrics[.claude])

        // No admin key → isClaudeAuthenticated == false.
        await manager.refreshAll()

        XCTAssertNil(manager.metrics[.claude], "Sections with no auth should be dropped from cache")
    }

    // MARK: - refresh(service:): single service

    func testRefreshSingleServiceForClaudeApiPopulatesOnlyThat() async {
        _ = auth.setClaudeAdminKey("sk-ant-test")
        stub.respond(when: matchClaudeApi, with: Data("""
            {"data":[{"input_tokens":42,"output_tokens":13}]}
            """.utf8), status: 200)

        await manager.refresh(service: .claude)

        XCTAssertNotNil(manager.metrics[.claude])
        XCTAssertNil(manager.metrics[.openai])
        XCTAssertNil(manager.metrics[.claudeCode])
    }

    func testRefreshSingleServiceWithoutAuthDoesNotFetch() async {
        await manager.refresh(service: .claude)

        XCTAssertNil(manager.metrics[.claude])
        XCTAssertTrue(stub.requests.isEmpty)
        XCTAssertNotNil(manager.lastError)
    }

    func testRefreshSingleServiceOn401DropsCachedSection() async throws {
        try writeClaudeCodeCredentials()
        manager = makeManager()

        manager.metrics[.claudeCode] = UsageMetrics(service: .claudeCode, limits: [
            UsageLimit(compactLabel: "S", verboseLabel: "Session", used: 30, total: 100)
        ])

        stub.respond(when: matchClaudeCodeUsage, with: Data(), status: 401)

        await manager.refresh(service: .claudeCode)

        XCTAssertNil(manager.metrics[.claudeCode])
    }

    func testRefreshSingleServiceOn500PreservesCachedSection() async throws {
        try writeClaudeCodeCredentials()
        manager = makeManager()

        let cached = UsageMetrics(service: .claudeCode, limits: [
            UsageLimit(compactLabel: "S", verboseLabel: "Session", used: 30, total: 100)
        ])
        manager.metrics[.claudeCode] = cached

        stub.respond(when: matchClaudeCodeUsage, with: Data("oops".utf8), status: 500)

        await manager.refresh(service: .claudeCode)

        XCTAssertEqual(manager.metrics[.claudeCode]?.limits.first?.used, 30)
        XCTAssertNotNil(manager.lastError)
    }

    // MARK: - Cache persistence

    func testRefreshAllPersistsMetricsToUserDefaults() async {
        _ = auth.setClaudeAdminKey("sk-ant-test")
        stub.respond(when: matchClaudeApi, with: Data("""
            {"data":[{"input_tokens":100,"output_tokens":50}]}
            """.utf8), status: 200)

        await manager.refreshAll()

        XCTAssertNotNil(userDefaults.data(forKey: "cached_usage_metrics_v2"))
    }

    func testInitLoadsCachedMetricsFromUserDefaults() throws {
        let cached: [String: UsageMetrics] = [
            ServiceType.claudeCode.rawValue: UsageMetrics(
                service: .claudeCode,
                limits: [UsageLimit(compactLabel: "S", verboseLabel: "Session", used: 50, total: 100)]
            )
        ]
        let data = try JSONEncoder().encode(cached)
        userDefaults.set(data, forKey: "cached_usage_metrics_v2")

        let restored = makeManager()

        XCTAssertEqual(restored.metrics.count, 1)
        XCTAssertEqual(restored.metrics[.claudeCode]?.limits.first?.used, 50)
    }

    func testInitIgnoresCorruptedCache() throws {
        userDefaults.set(Data("not json".utf8), forKey: "cached_usage_metrics_v2")

        let restored = makeManager()
        XCTAssertTrue(restored.metrics.isEmpty)
    }

    // MARK: - getNextRefreshTime

    func testGetNextRefreshTimeReturnsEarliestResetAcrossServices() {
        let early = Date(timeIntervalSinceNow: 60 * 60)
        let late = Date(timeIntervalSinceNow: 60 * 60 * 24)

        manager.metrics[.claudeCode] = UsageMetrics(service: .claudeCode, limits: [
            UsageLimit(compactLabel: "S", verboseLabel: "S", used: 10, total: 100, resetTime: late)
        ])
        manager.metrics[.cursor] = UsageMetrics(service: .cursor, limits: [
            UsageLimit(compactLabel: "M", verboseLabel: "M", used: 10, total: 100, resetTime: early)
        ])

        let next = manager.getNextRefreshTime()
        XCTAssertEqual(next, early)
    }

    func testGetNextRefreshTimeNilWhenNoResetTimes() {
        manager.metrics[.claudeCode] = UsageMetrics(service: .claudeCode, limits: [
            UsageLimit(compactLabel: "S", verboseLabel: "S", used: 10, total: 100, resetTime: nil)
        ])

        XCTAssertNil(manager.getNextRefreshTime())
    }

    func testGetNextRefreshTimeNilWhenNoMetrics() {
        XCTAssertNil(manager.getNextRefreshTime())
    }

    // MARK: - refreshInterval / setupAutoRefresh

    func testSettingRefreshIntervalUpdatesUserDefaultsAndRescheduleTimer() {
        manager.refreshInterval = .thirtyMinutes
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "refreshInterval"), RefreshInterval.thirtyMinutes.rawValue)
        XCTAssertEqual(manager.refreshInterval, .thirtyMinutes)

        // Restore to manual so the timer is invalidated before tearDown.
        manager.refreshInterval = .manual
        XCTAssertEqual(manager.refreshInterval, .manual)
    }

    // MARK: - Singleton

    func testSharedSingletonIsStable() {
        XCTAssertTrue(UsageDataManager.shared === UsageDataManager.shared)
    }

    // MARK: - Predicates (route URLProtocolStub responses to the right service)

    private func matchClaudeApi(_ request: URLRequest) -> Bool {
        return request.url?.host == "api.anthropic.com"
            && request.url?.path == "/v1/organizations/usage_report/messages"
    }

    private func matchClaudeCodeUsage(_ request: URLRequest) -> Bool {
        return request.url?.host == "api.anthropic.com"
            && request.url?.path == "/api/oauth/usage"
    }

    private func matchOpenAIUsage(_ request: URLRequest) -> Bool {
        return request.url?.host == "api.openai.com"
            && request.url?.path == "/v1/organization/usage/completions"
    }

    private func matchCodexUsage(_ request: URLRequest) -> Bool {
        return request.url?.host == "chatgpt.com"
            && request.url?.path == "/backend-api/wham/usage"
    }

    private func matchCursorUsage(_ request: URLRequest) -> Bool {
        return request.url?.host == "cursor.com"
            && request.url?.path == "/api/usage-summary"
    }

    // MARK: - Builders

    private func makeManager() -> UsageDataManager {
        let claudeService = ClaudeService(authManager: auth, urlSession: session)
        let claudeCodeService = ClaudeCodeLocalService(
            homeDirectory: claudeCodeHome.path,
            urlSession: session,
            keychainReader: { .failure(.apiError("no keychain in test")) }
        )
        let openaiService = OpenAIService(authManager: auth, urlSession: session)
        let codexCliService = CodexCliLocalService(homeDirectory: codexHome.path, urlSession: session)
        let cursorService = CursorLocalService(urlSession: session, authResolver: { _ in self.cursorAuthResult })

        return UsageDataManager(
            claudeService: claudeService,
            claudeCodeService: claudeCodeService,
            cursorService: cursorService,
            openaiService: openaiService,
            codexCliService: codexCliService,
            authManager: auth,
            sharedStore: sharedStore,
            userDefaults: userDefaults
        )
    }

    private func makeTempDir(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageDataManagerTests-\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeClaudeCodeCredentials() throws {
        let expiry = Int(Date().addingTimeInterval(60 * 60 * 24 * 365).timeIntervalSince1970 * 1000)
        let payload = """
        {"claudeAiOauth":{"accessToken":"token","refreshToken":"r","expiresAt":\(expiry),"subscriptionType":"pro","rateLimitTier":"pro"}}
        """
        try Data(payload.utf8).write(to: claudeCodeHome.appendingPathComponent(".claude/.credentials.json"))
    }

    private func writeCodexAuth() throws {
        let payload = """
        {"OPENAI_API_KEY":null,"tokens":{"id_token":"id","access_token":"token","refresh_token":"r","account_id":"acct-1"}}
        """
        try Data(payload.utf8).write(to: codexHome.appendingPathComponent(".codex/auth.json"))
    }
}
