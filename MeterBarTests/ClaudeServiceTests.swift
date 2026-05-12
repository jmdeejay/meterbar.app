import XCTest
@testable import MeterBar

final class ClaudeServiceTests: XCTestCase {
    private var stub: URLProtocolStub!
    private var session: URLSession!
    private var keychain: InMemoryKeychainBackend!
    private var auth: AuthenticationManager!
    private var service: ClaudeService!

    override func setUp() {
        super.setUp()
        stub = URLProtocolStub()
        session = URLProtocolStub.makeURLSession(with: stub)
        keychain = InMemoryKeychainBackend()
        auth = AuthenticationManager(keychain: keychain)
        service = ClaudeService(authManager: auth, urlSession: session)
    }

    private func matchesUsageReport(_ request: URLRequest) -> Bool {
        return request.url?.host == "api.anthropic.com"
            && request.url?.path == "/v1/organizations/usage_report/messages"
    }

    // MARK: - Auth gating

    func testFetchThrowsNotAuthenticatedWhenAdminKeyMissing() async {
        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("Expected ServiceError.notAuthenticated")
        } catch let err as ServiceError {
            if case .notAuthenticated = err {} else { XCTFail("Wrong error: \(err)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Happy path

    func testFetchAggregatesTokensAcrossBuckets() async throws {
        _ = auth.setClaudeAdminKey("sk-ant-admin-test")

        let payload = """
        {
          "data": [
            {"input_tokens": 1000, "output_tokens": 500},
            {"input_tokens": 2000, "output_tokens": 800}
          ]
        }
        """
        stub.respond(when: matchesUsageReport, with: Data(payload.utf8), status: 200)

        let metrics = try await service.fetchUsageMetrics()

        XCTAssertEqual(metrics.service, .claude)
        XCTAssertEqual(metrics.limits.count, 1)
        let weekly = try XCTUnwrap(metrics.limits.first)
        XCTAssertEqual(weekly.compactLabel, "W")
        XCTAssertEqual(weekly.used, 4300) // 1000 + 500 + 2000 + 800
        XCTAssertGreaterThan(weekly.total, weekly.used)
    }

    func testFetchSendsAdminKeyAndAnthropicVersionHeaders() async throws {
        _ = auth.setClaudeAdminKey("sk-ant-test")
        stub.respond(when: matchesUsageReport, with: Data("{\"data\":[]}".utf8), status: 200)

        _ = try await service.fetchUsageMetrics()

        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testFetchSendsExpectedQueryParameters() async throws {
        _ = auth.setClaudeAdminKey("sk-ant-test")
        stub.respond(when: matchesUsageReport, with: Data("{\"data\":[]}".utf8), status: 200)

        _ = try await service.fetchUsageMetrics()

        let url = try XCTUnwrap(stub.requests.first?.url)
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let names = comps.queryItems?.map { $0.name } ?? []
        XCTAssertTrue(names.contains("starting_at"))
        XCTAssertTrue(names.contains("ending_at"))
        XCTAssertTrue(names.contains("bucket_width"))
        XCTAssertTrue(names.contains("group_by[]"))
    }

    // MARK: - Error paths

    func testFetchOn401ThrowsNotAuthenticated() async {
        _ = auth.setClaudeAdminKey("sk-ant-bad")
        stub.respond(when: matchesUsageReport, with: Data(), status: 401)

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("Expected notAuthenticated")
        } catch let err as ServiceError {
            if case .notAuthenticated = err {} else { XCTFail("Wrong error: \(err)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchOn500ThrowsApiError() async {
        _ = auth.setClaudeAdminKey("sk-ant-test")
        stub.respond(when: matchesUsageReport, with: Data("oops".utf8), status: 500)

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("Expected apiError")
        } catch let err as ServiceError {
            guard case .apiError(let msg) = err else {
                XCTFail("Wrong error: \(err)"); return
            }
            XCTAssertTrue(msg.contains("500"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchOnUnparseableBodyThrows() async {
        _ = auth.setClaudeAdminKey("sk-ant-test")
        stub.respond(when: matchesUsageReport, with: Data("not json".utf8), status: 200)

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("Expected decoding error")
        } catch {
            // Any throw is acceptable — JSONDecoder produces DecodingError types.
        }
    }

    // MARK: - Autoclosure coverage for `?? 0` fallbacks

    func testFetchTreatsMissingTokenFieldsAsZero() async throws {
        _ = auth.setClaudeAdminKey("sk-ant-test")

        // Every token field is null → exercises the `?? 0` autoclosures that
        // never fire when fields are present.
        let payload = """
        {"data":[{"input_tokens":null,"output_tokens":null,"input_cached_tokens":null}]}
        """
        stub.respond(when: matchesUsageReport, with: Data(payload.utf8), status: 200)

        let metrics = try await service.fetchUsageMetrics()
        XCTAssertEqual(metrics.limits.first?.used, 0)
    }

    // MARK: - ServiceError descriptions

    func testServiceErrorDescriptions() {
        XCTAssertFalse(ServiceError.notAuthenticated.errorDescription?.isEmpty ?? true)
        XCTAssertFalse(ServiceError.invalidURL.errorDescription?.isEmpty ?? true)
        XCTAssertEqual(ServiceError.apiError("boom").errorDescription, "boom")
        XCTAssertFalse(ServiceError.parsingError.errorDescription?.isEmpty ?? true)
    }

    // MARK: - Singleton

    func testSharedSingletonIsStable() {
        XCTAssertTrue(ClaudeService.shared === ClaudeService.shared)
    }
}
