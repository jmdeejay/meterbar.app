import XCTest
@testable import MeterBar

/// Exercises `KeychainManager` against the **real** macOS keychain under a
/// per-process unique service identifier. We never touch the production
/// service id (`com.jmdeejay.meterbar`) so concurrent test runs don't trample
/// each other or the developer's saved Admin keys.
final class KeychainManagerTests: XCTestCase {
    private var service: String!
    private var keychain: KeychainManager!

    override func setUp() {
        super.setUp()
        service = "com.jmdeejay.meterbar.tests.\(UUID().uuidString)"
        keychain = KeychainManager(service: service)
    }

    override func tearDown() {
        // Best-effort cleanup of every key we may have written.
        for key in ["k1", "k2", "claude_admin_key", "openai_admin_key"] {
            _ = keychain.delete(key: key)
        }
        super.tearDown()
    }

    func testSaveAndGetRoundTrip() {
        XCTAssertTrue(keychain.save(key: "k1", value: "hello"))
        XCTAssertEqual(keychain.get(key: "k1"), "hello")
    }

    func testGetReturnsNilForMissingKey() {
        XCTAssertNil(keychain.get(key: "k1"))
    }

    func testSaveOverwritesExistingValue() {
        XCTAssertTrue(keychain.save(key: "k1", value: "first"))
        XCTAssertTrue(keychain.save(key: "k1", value: "second"))
        XCTAssertEqual(keychain.get(key: "k1"), "second")
    }

    func testDeleteRemovesValue() {
        XCTAssertTrue(keychain.save(key: "k1", value: "hello"))
        XCTAssertTrue(keychain.delete(key: "k1"))
        XCTAssertNil(keychain.get(key: "k1"))
    }

    func testDeleteOnMissingKeyReturnsTrue() {
        // delete() returns true on both errSecSuccess and errSecItemNotFound,
        // so deleting a non-existent key is a no-op success.
        XCTAssertTrue(keychain.delete(key: "k1"))
    }

    func testHasKeyTracksSaveAndDelete() {
        XCTAssertFalse(keychain.hasKey(key: "k1"))

        _ = keychain.save(key: "k1", value: "hello")
        XCTAssertTrue(keychain.hasKey(key: "k1"))

        _ = keychain.delete(key: "k1")
        XCTAssertFalse(keychain.hasKey(key: "k1"))
    }

    func testIndependentKeysDoNotInterfere() {
        _ = keychain.save(key: "k1", value: "a")
        _ = keychain.save(key: "k2", value: "b")

        XCTAssertEqual(keychain.get(key: "k1"), "a")
        XCTAssertEqual(keychain.get(key: "k2"), "b")

        _ = keychain.delete(key: "k1")

        XCTAssertNil(keychain.get(key: "k1"))
        XCTAssertEqual(keychain.get(key: "k2"), "b")
    }

    func testIsolatedFromOtherServiceIds() {
        let other = KeychainManager(service: "com.jmdeejay.meterbar.tests.\(UUID().uuidString)")
        _ = keychain.save(key: "k1", value: "mine")

        // Other service id sees nothing.
        XCTAssertNil(other.get(key: "k1"))

        // Cleanup of any item the other instance might have written.
        _ = other.delete(key: "k1")
    }

    func testSharedSingletonIsStable() {
        XCTAssertTrue(KeychainManager.shared === KeychainManager.shared)
    }
}
