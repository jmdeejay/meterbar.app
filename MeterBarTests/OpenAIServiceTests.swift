import XCTest
@testable import MeterBar

final class OpenAIServiceTests: XCTestCase {
    private var stub: URLProtocolStub!
    private var session: URLSession!
    private var keychain: InMemoryKeychainBackend!
    private var auth: AuthenticationManager!
    private var service: OpenAIService!

    override func setUp() {
        super.setUp()
        stub = URLProtocolStub()
        session = URLProtocolStub.makeURLSession(with: stub)
        keychain = InMemoryKeychainBackend()
        auth = AuthenticationManager(keychain: keychain)
        service = OpenAIService(authManager: auth, urlSession: session)
    }

    private func matchesUsageCompletions(_ request: URLRequest) -> Bool {
        return request.url?.host == "api.openai.com"
            && request.url?.path == "/v1/organization/usage/completions"
    }

    // MARK: - Auth gating

    func testFetchThrowsNotAuthenticatedWhenAdminKeyMissing() async {
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

    func testFetchAggregatesTokensAcrossBucketsAndResults() async throws {
        _ = auth.setOpenAIAdminKey("sk-openai-test")

        let payload = """
        {
          "data": [
            {"results": [
              {"input_tokens": 100, "output_tokens": 50, "num_model_requests": 1},
              {"input_tokens": 200, "output_tokens": 100, "num_model_requests": 2}
            ]},
            {"results": [
              {"input_tokens": 50, "output_tokens": 25, "num_model_requests": 1}
            ]}
          ]
        }
        """
        stub.respond(when: matchesUsageCompletions, with: Data(payload.utf8), status: 200)

        let metrics = try await service.fetchUsageMetrics()

        XCTAssertEqual(metrics.service, .openai)
        XCTAssertEqual(metrics.limits.count, 1)
        let weekly = try XCTUnwrap(metrics.limits.first)
        XCTAssertEqual(weekly.used, 525) // 100+50+200+100+50+25
    }

    func testFetchSendsBearerAuthorizationHeader() async throws {
        _ = auth.setOpenAIAdminKey("sk-openai-secret")
        stub.respond(when: matchesUsageCompletions, with: Data("{\"data\":[]}".utf8), status: 200)

        _ = try await service.fetchUsageMetrics()

        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-openai-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testFetchSendsExpectedQueryParameters() async throws {
        _ = auth.setOpenAIAdminKey("sk-openai-test")
        stub.respond(when: matchesUsageCompletions, with: Data("{\"data\":[]}".utf8), status: 200)

        _ = try await service.fetchUsageMetrics()

        let url = try XCTUnwrap(stub.requests.first?.url)
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let names = comps.queryItems?.map { $0.name } ?? []
        XCTAssertTrue(names.contains("start_time"))
        XCTAssertTrue(names.contains("end_time"))
        XCTAssertTrue(names.contains("bucket_width"))
        XCTAssertTrue(names.contains("group_by"))
    }

    // MARK: - Error paths

    func testFetchOn401ThrowsNotAuthenticated() async {
        _ = auth.setOpenAIAdminKey("sk-openai-bad")
        stub.respond(when: matchesUsageCompletions, with: Data(), status: 401)

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("Expected notAuthenticated")
        } catch let err as ServiceError {
            if case .notAuthenticated = err {} else { XCTFail("Wrong error: \(err)") }
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }

    func testFetchOn500ThrowsApiErrorContainingStatus() async {
        _ = auth.setOpenAIAdminKey("sk-openai-test")
        stub.respond(when: matchesUsageCompletions, with: Data("server died".utf8), status: 500)

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

    func testFetchOnUnparseableBodyThrows() async {
        _ = auth.setOpenAIAdminKey("sk-openai-test")
        stub.respond(when: matchesUsageCompletions, with: Data("not json".utf8), status: 200)

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("Expected decoding throw")
        } catch {
            // Decoding error is acceptable.
        }
    }

    // MARK: - Autoclosure coverage for `?? 0` fallbacks

    func testFetchTreatsMissingTokenFieldsAsZero() async throws {
        _ = auth.setOpenAIAdminKey("sk-openai-test")

        // All token fields explicitly null → exercises the `?? 0` autoclosures
        // that don't fire when the JSON provides values.
        let payload = """
        {"data":[{"results":[{"input_tokens":null,"output_tokens":null,"num_model_requests":null}]}]}
        """
        stub.respond(when: matchesUsageCompletions, with: Data(payload.utf8), status: 200)

        let metrics = try await service.fetchUsageMetrics()
        XCTAssertEqual(metrics.limits.first?.used, 0)
    }

    // MARK: - Singleton

    func testSharedSingletonIsStable() {
        XCTAssertTrue(OpenAIService.shared === OpenAIService.shared)
    }
}
