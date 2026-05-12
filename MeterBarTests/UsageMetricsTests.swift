import XCTest
@testable import MeterBar

final class UsageMetricsTests: XCTestCase {
    private func limit(_ used: Double, _ total: Double = 100, label: String = "L") -> UsageLimit {
        UsageLimit(compactLabel: label, verboseLabel: label, used: used, total: total)
    }

    // MARK: - Initialization

    func testInitializationWithLimits() {
        let metrics = UsageMetrics(
            service: .claudeCode,
            limits: [limit(50), limit(200, 500), limit(10, 50)]
        )

        XCTAssertEqual(metrics.service, .claudeCode)
        XCTAssertEqual(metrics.limits.count, 3)
    }

    func testInitializationWithNoLimits() {
        let metrics = UsageMetrics(service: .cursor)

        XCTAssertEqual(metrics.service, .cursor)
        XCTAssertTrue(metrics.limits.isEmpty)
    }

    func testIdIsUnique() {
        let metrics1 = UsageMetrics(service: .claudeCode)
        let metrics2 = UsageMetrics(service: .claudeCode)

        XCTAssertNotEqual(metrics1.id, metrics2.id)
    }

    // MARK: - hasData

    func testHasDataWithSingleLimit() {
        let metrics = UsageMetrics(service: .claudeCode, limits: [limit(50)])
        XCTAssertTrue(metrics.hasData)
    }

    func testHasDataWithNoLimits() {
        let metrics = UsageMetrics(service: .cursor)
        XCTAssertFalse(metrics.hasData)
    }

    // MARK: - overallStatus

    func testOverallStatusGoodWhenAllLimitsLow() {
        let metrics = UsageMetrics(
            service: .claudeCode,
            limits: [limit(20), limit(30)]
        )
        XCTAssertEqual(metrics.overallStatus, .good)
    }

    func testOverallStatusWarningWhenAnyLimitNearLimit() {
        let metrics = UsageMetrics(
            service: .claudeCode,
            limits: [limit(20), limit(85)] // 85% triggers warning
        )
        XCTAssertEqual(metrics.overallStatus, .warning)
    }

    func testOverallStatusCriticalWhenAnyLimitAtLimit() {
        let metrics = UsageMetrics(
            service: .claudeCode,
            limits: [limit(100), limit(50)]
        )
        XCTAssertEqual(metrics.overallStatus, .critical)
    }

    func testOverallStatusCriticalOverridesWarning() {
        let metrics = UsageMetrics(
            service: .claudeCode,
            limits: [limit(120), limit(85)]
        )
        XCTAssertEqual(metrics.overallStatus, .critical)
    }

    func testOverallStatusGoodWhenNoLimits() {
        let metrics = UsageMetrics(service: .cursor)
        XCTAssertEqual(metrics.overallStatus, .good)
    }

    // MARK: - Codable

    func testCodable() throws {
        let original = UsageMetrics(
            service: .claudeCode,
            limits: [
                UsageLimit(compactLabel: "S", verboseLabel: "Session (5h)", used: 50, total: 100, resetTime: Date()),
                UsageLimit(compactLabel: "W", verboseLabel: "Weekly", used: 200, total: 500)
            ]
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UsageMetrics.self, from: encoded)

        XCTAssertEqual(decoded.service, original.service)
        XCTAssertEqual(decoded.limits.count, 2)
        XCTAssertEqual(decoded.limits.first?.compactLabel, "S")
        XCTAssertEqual(decoded.limits.first?.verboseLabel, "Session (5h)")
        XCTAssertEqual(decoded.limits.first?.used, 50)
        XCTAssertEqual(decoded.limits.last?.total, 500)
    }
}
