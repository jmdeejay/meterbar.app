import XCTest
@testable import MeterBar

final class NotificationDeduperTests: XCTestCase {

    private let resetA = Date(timeIntervalSince1970: 1_700_000_000)
    private let resetB = Date(timeIntervalSince1970: 1_700_000_000 + 5 * 3600)

    private func key(
        _ service: ServiceType = .claudeCode,
        _ limit: String = "session",
        _ tier: NotificationDeduper.Tier = .warning
    ) -> NotificationDeduper.Key {
        NotificationDeduper.Key(service: service, limitName: limit, tier: tier)
    }

    // MARK: - Single-key behaviour

    func testFirstCallAlwaysFires() {
        var d = NotificationDeduper()
        XCTAssertTrue(d.shouldNotify(key: key(), currentResetTime: resetA))
    }

    func testSameResetTimeSkipsAfterFirstCall() {
        var d = NotificationDeduper()
        XCTAssertTrue(d.shouldNotify(key: key(), currentResetTime: resetA))
        XCTAssertFalse(d.shouldNotify(key: key(), currentResetTime: resetA))
        XCTAssertFalse(d.shouldNotify(key: key(), currentResetTime: resetA))
    }

    func testAdvancedResetTimeFiresAgain() {
        var d = NotificationDeduper()
        XCTAssertTrue(d.shouldNotify(key: key(), currentResetTime: resetA))
        XCTAssertFalse(d.shouldNotify(key: key(), currentResetTime: resetA))
        XCTAssertTrue(d.shouldNotify(key: key(), currentResetTime: resetB))
        XCTAssertFalse(d.shouldNotify(key: key(), currentResetTime: resetB))
    }

    // MARK: - Nil reset time (ambiguous window) is conservative

    func testNilResetTimeFiresOnceAndNeverAgain() {
        var d = NotificationDeduper()
        XCTAssertTrue(d.shouldNotify(key: key(), currentResetTime: nil))
        XCTAssertFalse(d.shouldNotify(key: key(), currentResetTime: nil))
    }

    func testNilThenValueDoesNotRefire() {
        // Window unknowable across the transition — skip rather than risk a spurious notification.
        var d = NotificationDeduper()
        XCTAssertTrue(d.shouldNotify(key: key(), currentResetTime: nil))
        XCTAssertFalse(d.shouldNotify(key: key(), currentResetTime: resetA))
    }

    func testValueThenNilDoesNotRefire() {
        var d = NotificationDeduper()
        XCTAssertTrue(d.shouldNotify(key: key(), currentResetTime: resetA))
        XCTAssertFalse(d.shouldNotify(key: key(), currentResetTime: nil))
    }

    // MARK: - Independence across keys

    func testDifferentServicesTrackedSeparately() {
        var d = NotificationDeduper()
        XCTAssertTrue(d.shouldNotify(key: key(.claudeCode), currentResetTime: resetA))
        XCTAssertTrue(d.shouldNotify(key: key(.cursor), currentResetTime: resetA))
        XCTAssertFalse(d.shouldNotify(key: key(.claudeCode), currentResetTime: resetA))
        XCTAssertFalse(d.shouldNotify(key: key(.cursor), currentResetTime: resetA))
    }

    func testDifferentLimitNamesTrackedSeparately() {
        var d = NotificationDeduper()
        XCTAssertTrue(d.shouldNotify(key: key(.claudeCode, "session"), currentResetTime: resetA))
        XCTAssertTrue(d.shouldNotify(key: key(.claudeCode, "weekly"), currentResetTime: resetA))
        XCTAssertTrue(d.shouldNotify(key: key(.claudeCode, "codeReview"), currentResetTime: resetA))
    }

    func testDifferentTiersTrackedSeparately() {
        // Crossing 90% then later 100% should produce two separate notifications.
        var d = NotificationDeduper()
        XCTAssertTrue(d.shouldNotify(key: key(.claudeCode, "session", .warning), currentResetTime: resetA))
        XCTAssertTrue(d.shouldNotify(key: key(.claudeCode, "session", .reached), currentResetTime: resetA))
        XCTAssertFalse(d.shouldNotify(key: key(.claudeCode, "session", .warning), currentResetTime: resetA))
        XCTAssertFalse(d.shouldNotify(key: key(.claudeCode, "session", .reached), currentResetTime: resetA))
    }
}
