import XCTest
@testable import MeterBar

@MainActor
final class CodexCliLocalServiceTests: XCTestCase {
    private var home: URL!
    private var stub: URLProtocolStub!
    private var session: URLSession!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexCliLocalServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex"),
            withIntermediateDirectories: true
        )
        stub = URLProtocolStub()
        session = URLProtocolStub.makeURLSession(with: stub)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func matchesUsage(_ request: URLRequest) -> Bool {
        return request.url?.host == "chatgpt.com"
            && request.url?.path == "/backend-api/wham/usage"
    }

    private func writeAuth(token: String = "codex-token", accountId: String? = "acct-123") throws {
        let body: String
        if let accountId = accountId {
            body = """
            {"OPENAI_API_KEY":null,"tokens":{"id_token":"id","access_token":"\(token)","refresh_token":"r","account_id":"\(accountId)"}}
            """
        } else {
            body = """
            {"OPENAI_API_KEY":null,"tokens":{"id_token":"id","access_token":"\(token)","refresh_token":"r","account_id":null}}
            """
        }
        try Data(body.utf8).write(to: home.appendingPathComponent(".codex/auth.json"))
    }

    private func makeService() -> CodexCliLocalService {
        CodexCliLocalService(homeDirectory: home.path, urlSession: session)
    }

    // MARK: - Auth / file presence

    func testCheckAccessFalseWhenNoAuthFile() {
        let service = makeService()
        XCTAssertFalse(service.hasAccess)
    }

    func testCheckAccessTrueWhenAuthFileHasAccessToken() throws {
        try writeAuth()
        let service = makeService()
        XCTAssertTrue(service.hasAccess)
    }

    func testFetchThrowsNotAuthenticatedWhenNoAuthFile() async {
        let service = makeService()

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("Expected notAuthenticated")
        } catch let err as ServiceError {
            if case .notAuthenticated = err {} else { XCTFail("Wrong error: \(err)") }
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }

    // MARK: - Happy path

    func testFetchPlanTypeAndSessionWindowFromRateLimit() async throws {
        try writeAuth()
        let service = makeService()

        let payload = """
        {
          "plan_type": "team",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {"used_percent": 12.5, "limit_window_seconds": 18000, "reset_after_seconds": 1000, "reset_at": 1788000000},
            "secondary_window": {"used_percent": 45.0, "limit_window_seconds": 604800, "reset_after_seconds": 100000, "reset_at": 1788500000}
          },
          "code_review_rate_limit": null,
          "credits": null
        }
        """
        stub.respond(when: matchesUsage, with: Data(payload.utf8), status: 200)

        let metrics = try await service.fetchUsageMetrics()
        XCTAssertEqual(metrics.service, .codexCli)
        XCTAssertEqual(service.subscriptionType, "team")
        XCTAssertEqual(metrics.limits.count, 2)
        XCTAssertEqual(metrics.limits[0].compactLabel, "S")
        XCTAssertEqual(metrics.limits[0].used, 12.5)
        XCTAssertEqual(metrics.limits[1].compactLabel, "W")
        XCTAssertEqual(metrics.limits[1].used, 45.0)
    }

    func testFetchAppendsCodeReviewLimitWhenPresent() async throws {
        try writeAuth()
        let service = makeService()

        let payload = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {"used_percent": 5, "limit_window_seconds": 18000, "reset_after_seconds": 1, "reset_at": 1788000000},
            "secondary_window": null
          },
          "code_review_rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {"used_percent": 70, "limit_window_seconds": 604800, "reset_after_seconds": 1, "reset_at": 1788400000},
            "secondary_window": null
          },
          "credits": null
        }
        """
        stub.respond(when: matchesUsage, with: Data(payload.utf8), status: 200)

        let metrics = try await service.fetchUsageMetrics()
        XCTAssertEqual(metrics.limits.count, 3)
        XCTAssertEqual(metrics.limits.last?.compactLabel, "CR")
        XCTAssertEqual(metrics.limits.last?.used, 70)
    }

    func testFetchReturnsEmptyLimitsWhenRateLimitNull() async throws {
        try writeAuth()
        let service = makeService()

        let payload = """
        {"plan_type": "free", "rate_limit": null, "code_review_rate_limit": null, "credits": null}
        """
        stub.respond(when: matchesUsage, with: Data(payload.utf8), status: 200)

        let metrics = try await service.fetchUsageMetrics()
        XCTAssertEqual(metrics.service, .codexCli)
        XCTAssertTrue(metrics.limits.isEmpty)
    }

    func testFetchSendsBearerTokenAndAccountIdHeader() async throws {
        try writeAuth(token: "token-secret", accountId: "acct-secret")
        let service = makeService()
        stub.respond(when: matchesUsage, with: Data("""
            {"plan_type":"free","rate_limit":null,"code_review_rate_limit":null,"credits":null}
            """.utf8), status: 200)

        _ = try await service.fetchUsageMetrics()

        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://chatgpt.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://chatgpt.com/")
    }

    func testFetchOmitsAccountIdHeaderWhenAuthHasNone() async throws {
        try writeAuth(token: "token-only", accountId: nil)
        let service = makeService()
        stub.respond(when: matchesUsage, with: Data("""
            {"plan_type":"free","rate_limit":null,"code_review_rate_limit":null,"credits":null}
            """.utf8), status: 200)

        _ = try await service.fetchUsageMetrics()

        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"))
    }

    // MARK: - Error paths

    func testFetchOn401ThrowsNotAuthenticated() async throws {
        try writeAuth()
        let service = makeService()
        stub.respond(when: matchesUsage, with: Data(), status: 401)

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("Expected notAuthenticated")
        } catch let err as ServiceError {
            if case .notAuthenticated = err {} else { XCTFail("Wrong error: \(err)") }
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }

    func testFetchOn500ThrowsApiError() async throws {
        try writeAuth()
        let service = makeService()
        stub.respond(when: matchesUsage, with: Data("server died".utf8), status: 500)

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("Expected apiError")
        } catch let err as ServiceError {
            guard case .apiError(let msg) = err else {
                XCTFail("Wrong error: \(err)"); return
            }
            XCTAssertTrue(msg.contains("500"))
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }

    // MARK: - Singleton

    func testSharedSingletonIsStable() {
        XCTAssertTrue(CodexCliLocalService.shared === CodexCliLocalService.shared)
    }
}
