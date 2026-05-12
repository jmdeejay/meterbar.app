import XCTest
@testable import MeterBar

final class UsageLimitTests: XCTestCase {
    private func makeLimit(used: Double, total: Double) -> UsageLimit {
        UsageLimit(compactLabel: "T", verboseLabel: "Test", used: used, total: total, resetTime: nil)
    }

    func testPercentageAndRemainingValues() {
        let limit = makeLimit(used: 25, total: 100)

        XCTAssertEqual(limit.percentage, 25, accuracy: 0.01)
        XCTAssertEqual(limit.remaining, 75, accuracy: 0.01)
        XCTAssertFalse(limit.isNearLimit)
        XCTAssertFalse(limit.isAtLimit)
        XCTAssertEqual(limit.statusColor, .good)
    }

    func testClampsPercentageAtBounds() {
        let overLimit = makeLimit(used: 120, total: 100)
        let zeroTotal = makeLimit(used: 50, total: 0)

        XCTAssertEqual(overLimit.percentage, 100, accuracy: 0.01)
        XCTAssertEqual(overLimit.remaining, 0, accuracy: 0.01)
        XCTAssertTrue(overLimit.isAtLimit)
        XCTAssertEqual(overLimit.statusColor, .critical)

        XCTAssertEqual(zeroTotal.percentage, 0, accuracy: 0.01)
        XCTAssertEqual(zeroTotal.remaining, 0, accuracy: 0.01)
        XCTAssertFalse(zeroTotal.isNearLimit)
        XCTAssertEqual(zeroTotal.statusColor, .good)
    }

    func testWarningThreshold() {
        let nearLimit = makeLimit(used: 85, total: 100)

        XCTAssertTrue(nearLimit.isNearLimit)
        XCTAssertFalse(nearLimit.isAtLimit)
        XCTAssertEqual(nearLimit.statusColor, .warning)
    }

    // MARK: - Codable round-trip

    func testCodableRoundTripPreservesFields() throws {
        let reset = Date(timeIntervalSince1970: 1_700_000_000)
        let original = UsageLimit(
            compactLabel: "S",
            verboseLabel: "Session (5h)",
            used: 42.5,
            total: 100,
            resetTime: reset
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UsageLimit.self, from: encoded)

        XCTAssertEqual(decoded.compactLabel, original.compactLabel)
        XCTAssertEqual(decoded.verboseLabel, original.verboseLabel)
        XCTAssertEqual(decoded.used, original.used, accuracy: 0.001)
        XCTAssertEqual(decoded.total, original.total, accuracy: 0.001)
        XCTAssertEqual(decoded.resetTime, original.resetTime)
    }

    // MARK: - UsageStatus.color

    func testUsageStatusColorsAreDistinct() {
        XCTAssertNotEqual(UsageStatus.good.color, UsageStatus.warning.color)
        XCTAssertNotEqual(UsageStatus.warning.color, UsageStatus.critical.color)
        XCTAssertNotEqual(UsageStatus.good.color, UsageStatus.critical.color)
    }

    func testUsageStatusColorIsStableForEachCase() {
        XCTAssertEqual(UsageStatus.good.color, UsageStatus.good.color)
        XCTAssertEqual(UsageStatus.warning.color, UsageStatus.warning.color)
        XCTAssertEqual(UsageStatus.critical.color, UsageStatus.critical.color)
    }
}
