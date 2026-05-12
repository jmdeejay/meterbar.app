import XCTest
@testable import MeterBar

final class AuthenticationManagerTests: XCTestCase {
    private var keychain: InMemoryKeychainBackend!
    private var auth: AuthenticationManager!

    override func setUp() {
        super.setUp()
        keychain = InMemoryKeychainBackend()
        auth = AuthenticationManager(keychain: keychain)
    }

    // MARK: - Initial load

    func testInitWithEmptyKeychainExposesNilCredentials() {
        XCTAssertNil(auth.claudeAdminKey)
        XCTAssertNil(auth.openaiAdminKey)
        XCTAssertFalse(auth.isClaudeAuthenticated)
        XCTAssertFalse(auth.isOpenAIAuthenticated)
    }

    func testInitLoadsExistingKeysFromKeychain() {
        keychain.storage["claude_admin_key"] = "sk-ant-existing"
        keychain.storage["openai_admin_key"] = "sk-openai-existing"

        let restored = AuthenticationManager(keychain: keychain)

        XCTAssertEqual(restored.claudeAdminKey, "sk-ant-existing")
        XCTAssertEqual(restored.openaiAdminKey, "sk-openai-existing")
        XCTAssertTrue(restored.isClaudeAuthenticated)
        XCTAssertTrue(restored.isOpenAIAuthenticated)
    }

    // MARK: - Set / remove

    func testSetClaudeAdminKeyPersistsAndPublishes() {
        XCTAssertTrue(auth.setClaudeAdminKey("sk-ant-new"))
        XCTAssertEqual(auth.claudeAdminKey, "sk-ant-new")
        XCTAssertEqual(keychain.storage["claude_admin_key"], "sk-ant-new")
        XCTAssertTrue(auth.isClaudeAuthenticated)
    }

    func testSetClaudeAdminKeyDoesNotTouchOpenAI() {
        _ = auth.setClaudeAdminKey("sk-ant-only")
        XCTAssertNil(auth.openaiAdminKey)
        XCTAssertNil(keychain.storage["openai_admin_key"])
    }

    func testSetOpenAIAdminKeyPersistsAndPublishes() {
        XCTAssertTrue(auth.setOpenAIAdminKey("sk-openai-new"))
        XCTAssertEqual(auth.openaiAdminKey, "sk-openai-new")
        XCTAssertEqual(keychain.storage["openai_admin_key"], "sk-openai-new")
        XCTAssertTrue(auth.isOpenAIAuthenticated)
    }

    func testRemoveClaudeAdminKeyClearsBothStateAndStorage() {
        _ = auth.setClaudeAdminKey("sk-ant-temp")
        auth.removeClaudeAdminKey()

        XCTAssertNil(auth.claudeAdminKey)
        XCTAssertNil(keychain.storage["claude_admin_key"])
        XCTAssertFalse(auth.isClaudeAuthenticated)
    }

    func testRemoveOpenAIAdminKeyClearsBothStateAndStorage() {
        _ = auth.setOpenAIAdminKey("sk-openai-temp")
        auth.removeOpenAIAdminKey()

        XCTAssertNil(auth.openaiAdminKey)
        XCTAssertNil(keychain.storage["openai_admin_key"])
        XCTAssertFalse(auth.isOpenAIAuthenticated)
    }

    func testRemoveClaudeDoesNotTouchOpenAI() {
        _ = auth.setClaudeAdminKey("sk-ant")
        _ = auth.setOpenAIAdminKey("sk-openai")

        auth.removeClaudeAdminKey()

        XCTAssertNil(auth.claudeAdminKey)
        XCTAssertEqual(auth.openaiAdminKey, "sk-openai")
        XCTAssertEqual(keychain.storage["openai_admin_key"], "sk-openai")
    }

    // MARK: - Failure modes

    func testSetClaudeAdminKeyReturnsFalseWhenKeychainSaveFails() {
        keychain.shouldFailSaves = true

        XCTAssertFalse(auth.setClaudeAdminKey("sk-ant"))
        XCTAssertNil(auth.claudeAdminKey)
        XCTAssertNil(keychain.storage["claude_admin_key"])
    }

    func testSetOpenAIAdminKeyReturnsFalseWhenKeychainSaveFails() {
        keychain.shouldFailSaves = true

        XCTAssertFalse(auth.setOpenAIAdminKey("sk-openai"))
        XCTAssertNil(auth.openaiAdminKey)
        XCTAssertNil(keychain.storage["openai_admin_key"])
    }

    // MARK: - Constants

    func testCursorIsAlwaysReportedUnauthenticated() {
        // Cursor uses local SQLite auth — AuthenticationManager doesn't track it.
        XCTAssertFalse(auth.isCursorAuthenticated)
    }

    func testSharedSingletonIsStable() {
        XCTAssertTrue(AuthenticationManager.shared === AuthenticationManager.shared)
    }
}

/// Dictionary-backed `KeychainBackend` used for `AuthenticationManager` tests.
/// `shouldFailSaves` lets us simulate keychain write failures without touching
/// the real keychain.
final class InMemoryKeychainBackend: KeychainBackend {
    var storage: [String: String] = [:]
    var shouldFailSaves: Bool = false

    func save(key: String, value: String) -> Bool {
        if shouldFailSaves { return false }
        storage[key] = value
        return true
    }

    func get(key: String) -> String? {
        return storage[key]
    }

    func delete(key: String) -> Bool {
        storage.removeValue(forKey: key)
        return true
    }
}
