import XCTest
@testable import MeterBar

/// Network-path tests for `ClaudeCodeLocalService`. The credential-resolver
/// paths are covered by `ClaudeCodeLocalServiceTests` (which only exercises
/// the static `ClaudeCodeCredentialResolver`). These tests drive the full
/// `fetchUsageMetrics()` → `performUsageRequest()` pipeline against a stubbed
/// URLSession + fake keychain reader.
final class ClaudeCodeLocalServiceNetworkTests: XCTestCase {
    private var home: URL!
    private var stub: URLProtocolStub!
    private var session: URLSession!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCodeLocalServiceNetworkTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        stub = URLProtocolStub()
        session = URLProtocolStub.makeURLSession(with: stub)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func matchesUsage(_ request: URLRequest) -> Bool {
        return request.url?.host == "api.anthropic.com"
            && request.url?.path == "/api/oauth/usage"
    }

    private func writeCredentialsFile(token: String = "test-token", expiresAtMillis: Double? = nil) throws {
        // Default: 1 year from now → proactive re-import won't fire.
        let expiry = expiresAtMillis ?? (Date().addingTimeInterval(60 * 60 * 24 * 365).timeIntervalSince1970 * 1000)
        let payload = """
        {
          "claudeAiOauth": {
            "accessToken": "\(token)",
            "refreshToken": "refresh-token",
            "expiresAt": \(Int(expiry)),
            "subscriptionType": "pro",
            "rateLimitTier": "pro"
          }
        }
        """
        try Data(payload.utf8).write(to: home.appendingPathComponent(".claude/.credentials.json"))
    }

    private func makeService(keychainOverride: (() -> Result<Data, ServiceError>)? = nil) -> ClaudeCodeLocalService {
        return ClaudeCodeLocalService(
            homeDirectory: home.path,
            urlSession: session,
            keychainReader: keychainOverride ?? { .failure(.apiError("no keychain in test")) }
        )
    }

    // MARK: - Unauthenticated

    func testFetchThrowsNotAuthenticatedWhenNoCredentials() async {
        let service = makeService()
        XCTAssertFalse(service.hasAccess)

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

    func testFetchReturnsTwoLimitsForSessionAndWeekly() async throws {
        try writeCredentialsFile()
        let service = makeService()
        XCTAssertTrue(service.hasAccess)

        let payload = """
        {
          "five_hour": {"utilization": 25.5, "resets_at": "2026-05-12T15:00:00Z"},
          "seven_day": {"utilization": 60.0, "resets_at": "2026-05-19T00:00:00Z"}
        }
        """
        stub.respond(when: matchesUsage, with: Data(payload.utf8), status: 200)

        let metrics = try await service.fetchUsageMetrics()
        XCTAssertEqual(metrics.service, .claudeCode)
        XCTAssertEqual(metrics.limits.count, 2)
        XCTAssertEqual(metrics.limits[0].compactLabel, "S")
        XCTAssertEqual(metrics.limits[0].used, 25.5)
        XCTAssertEqual(metrics.limits[1].compactLabel, "W")
        XCTAssertEqual(metrics.limits[1].used, 60.0)
    }

    func testFetchReturnsThreeLimitsWhenSonnetWindowPresent() async throws {
        try writeCredentialsFile()
        let service = makeService()

        let payload = """
        {
          "five_hour": {"utilization": 10, "resets_at": "2026-05-12T15:00:00Z"},
          "seven_day": {"utilization": 20, "resets_at": "2026-05-19T00:00:00Z"},
          "seven_day_sonnet": {"utilization": 40.0, "resets_at": "2026-05-19T00:00:00Z"}
        }
        """
        stub.respond(when: matchesUsage, with: Data(payload.utf8), status: 200)

        let metrics = try await service.fetchUsageMetrics()
        XCTAssertEqual(metrics.limits.count, 3)
        XCTAssertEqual(metrics.limits.last?.compactLabel, "Sn")
        XCTAssertEqual(metrics.limits.last?.used, 40.0)
    }

    func testFetchSendsBearerTokenAndAnthropicBetaHeader() async throws {
        try writeCredentialsFile(token: "sk-ant-test-token")
        let service = makeService()
        stub.respond(when: matchesUsage, with: Data("""
            {"five_hour":{"utilization":0},"seven_day":{"utilization":0}}
            """.utf8), status: 200)

        _ = try await service.fetchUsageMetrics()

        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-ant-test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    // MARK: - Error paths

    func testFetchOn401WithKeychainReaderFailureThrowsNotAuthenticated() async throws {
        try writeCredentialsFile()
        let service = makeService(keychainOverride: { .failure(.apiError("no keychain item")) })

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
        try writeCredentialsFile()
        let service = makeService()
        stub.respond(when: matchesUsage, with: Data("oops".utf8), status: 500)

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

    func testFetchOnUnparseableBodyThrows() async throws {
        try writeCredentialsFile()
        let service = makeService()
        stub.respond(when: matchesUsage, with: Data("garbage".utf8), status: 200)

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("Expected throw on bad body")
        } catch {
            // Either parsingError or DecodingError is acceptable.
        }
    }

    // MARK: - importCredentialsFromKeychain

    func testImportFromKeychainWithInjectedReaderWritesCredentialsFile() throws {
        let payload = """
        {"claudeAiOauth":{"accessToken":"sk-ant-imported","refreshToken":"r","expiresAt":\(Int(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)),"subscriptionType":"pro","rateLimitTier":"pro"}}
        """
        let service = makeService(keychainOverride: { .success(Data(payload.utf8)) })

        let result = service.importCredentialsFromKeychain()
        switch result {
        case .success:
            let writtenPath = home.appendingPathComponent(".claude/.credentials.json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: writtenPath.path))
            XCTAssertTrue(service.hasAccess)
        case .failure(let err):
            XCTFail("Expected success, got: \(err)")
        }
    }

    func testImportFromKeychainPropagatesKeychainErrorMessage() {
        let service = makeService(keychainOverride: {
            .failure(.apiError("Keychain access denied."))
        })

        let result = service.importCredentialsFromKeychain()
        if case .failure(.apiError(let msg)) = result {
            XCTAssertTrue(msg.contains("Keychain"))
        } else {
            XCTFail("Expected apiError")
        }
    }

    // MARK: - Singleton

    func testSharedSingletonIsStable() {
        XCTAssertTrue(ClaudeCodeLocalService.shared === ClaudeCodeLocalService.shared)
    }
}
