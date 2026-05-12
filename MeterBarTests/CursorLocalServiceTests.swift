import XCTest
@testable import MeterBar

final class CursorLocalServiceTests: XCTestCase {
    private var stub: URLProtocolStub!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        stub = URLProtocolStub()
        session = URLProtocolStub.makeURLSession(with: stub)
    }

    private func matchesUsageSummary(_ request: URLRequest) -> Bool {
        return request.url?.host == "cursor.com"
            && request.url?.path == "/api/usage-summary"
    }

    private func makeService(authResolver: @escaping (Bool) -> (String, String)? = { _ in ("user-1", "tok-1") }) -> CursorLocalService {
        CursorLocalService(urlSession: session, authResolver: authResolver)
    }

    // MARK: - Auth gating

    func testCheckAccessFalseWhenResolverReturnsNil() {
        let service = makeService(authResolver: { _ in nil })
        XCTAssertFalse(service.hasAccess)
    }

    func testCheckAccessTrueWhenResolverReturnsToken() {
        let service = makeService()
        XCTAssertTrue(service.hasAccess)
    }

    func testFetchThrowsNotAuthenticatedWhenResolverReturnsNil() async {
        let service = makeService(authResolver: { _ in nil })

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

    func testFetchReturnsApiAndMonthlyLimits() async throws {
        let service = makeService()

        let payload = """
        {
          "billingCycleEnd": "2026-06-01T00:00:00.000Z",
          "membershipType": "pro",
          "individualUsage": {
            "plan": {
              "used": 100,
              "limit": 200,
              "totalPercentUsed": 50.0,
              "autoPercentUsed": 20.0,
              "apiPercentUsed": 30.0
            },
            "onDemand": {"used": 0, "limit": 0, "enabled": false}
          }
        }
        """
        stub.respond(when: matchesUsageSummary, with: Data(payload.utf8), status: 200)

        let metrics = try await service.fetchUsageMetrics()
        XCTAssertEqual(metrics.service, .cursor)
        XCTAssertEqual(service.subscriptionType, "pro")
        XCTAssertEqual(metrics.limits.count, 2)
        XCTAssertEqual(metrics.limits[0].compactLabel, "API")
        XCTAssertEqual(metrics.limits[0].used, 30.0)
        XCTAssertEqual(metrics.limits[1].compactLabel, "M")
        XCTAssertEqual(metrics.limits[1].used, 50.0)
    }

    func testFetchInsertsOnDemandLimitWhenEnabledAndHasUsage() async throws {
        let service = makeService()

        let payload = """
        {
          "billingCycleEnd": "2026-06-01T00:00:00.000Z",
          "membershipType": "pro",
          "individualUsage": {
            "plan": {"totalPercentUsed": 50, "autoPercentUsed": 30, "apiPercentUsed": 20},
            "onDemand": {"used": 5, "limit": 10, "enabled": true}
          }
        }
        """
        stub.respond(when: matchesUsageSummary, with: Data(payload.utf8), status: 200)

        let metrics = try await service.fetchUsageMetrics()
        XCTAssertEqual(metrics.limits.count, 3)
        XCTAssertEqual(metrics.limits[1].compactLabel, "OD")
        XCTAssertEqual(metrics.limits[1].used, 5)
        XCTAssertEqual(metrics.limits[1].total, 10)
    }

    func testFetchSkipsOnDemandWhenDisabled() async throws {
        let service = makeService()

        let payload = """
        {
          "membershipType": "free",
          "individualUsage": {
            "plan": {"totalPercentUsed": 10, "autoPercentUsed": 0, "apiPercentUsed": 10},
            "onDemand": {"used": 0, "limit": 0, "enabled": false}
          }
        }
        """
        stub.respond(when: matchesUsageSummary, with: Data(payload.utf8), status: 200)

        let metrics = try await service.fetchUsageMetrics()
        XCTAssertEqual(metrics.limits.count, 2)
        XCTAssertFalse(metrics.limits.contains { $0.compactLabel == "OD" })
    }

    func testFetchSendsBrowserishCookieAndHeaders() async throws {
        let service = makeService(authResolver: { _ in ("user-xyz", "jwt-abc") })
        stub.respond(when: matchesUsageSummary, with: Data("""
            {"membershipType":"free","individualUsage":{"plan":{"totalPercentUsed":0,"autoPercentUsed":0,"apiPercentUsed":0},"onDemand":{"enabled":false}}}
            """.utf8), status: 200)

        _ = try await service.fetchUsageMetrics()

        let request = try XCTUnwrap(stub.requests.first)
        let cookie = try XCTUnwrap(request.value(forHTTPHeaderField: "Cookie"))
        // Cookie shape: WorkosCursorSessionToken=<userId>%3A%3A<token>
        XCTAssertTrue(cookie.contains("WorkosCursorSessionToken="))
        XCTAssertTrue(cookie.contains("user-xyz%3A%3Ajwt-abc"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://cursor.com")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Referer"))
    }

    // MARK: - Error paths

    func testFetchOn401ThrowsNotAuthenticated() async {
        let service = makeService()
        stub.respond(when: matchesUsageSummary, with: Data(), status: 401)

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("Expected notAuthenticated")
        } catch let err as ServiceError {
            if case .notAuthenticated = err {} else { XCTFail("Wrong error: \(err)") }
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }

    func testFetchOn500ThrowsApiError() async {
        let service = makeService()
        stub.respond(when: matchesUsageSummary, with: Data("server died".utf8), status: 500)

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

    func testFetchOnUnparseableBodyThrowsParsingError() async {
        let service = makeService()
        stub.respond(when: matchesUsageSummary, with: Data("not json".utf8), status: 200)

        do {
            _ = try await service.fetchUsageMetrics()
            XCTFail("Expected parsingError")
        } catch let err as ServiceError {
            if case .parsingError = err {} else { XCTFail("Wrong error: \(err)") }
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }

    // MARK: - Singleton

    func testSharedSingletonIsStable() {
        XCTAssertTrue(CursorLocalService.shared === CursorLocalService.shared)
    }
}
