import XCTest
@testable import MeterBar

final class ClaudeCodeKeychainImportTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-keychain-import-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempHome = tempHome, FileManager.default.fileExists(atPath: tempHome.path) {
            try FileManager.default.removeItem(at: tempHome)
        }
    }

    private static let validKeychainPayload: Data = #"""
    {"claudeAiOauth":{"accessToken":"test-token","refreshToken":"r","expiresAt":0,"scopes":[]}}
    """#.data(using: .utf8)!

    private var expectedFilePath: String {
        tempHome.appendingPathComponent(".claude/.credentials.json").path
    }

    // MARK: - Success path

    func testWritesCredentialsFileWithKeychainPayloadVerbatim() throws {
        let result = ClaudeCodeKeychainImport.importCredentials(
            from: Self.validKeychainPayload,
            homeDirectory: tempHome.path
        )
        XCTAssertNoThrow(try result.get())
        let written = try Data(contentsOf: URL(fileURLWithPath: expectedFilePath))
        XCTAssertEqual(written, Self.validKeychainPayload)
    }

    func testCreatesClaudeDirectoryWhenMissing() {
        let claudeDir = tempHome.appendingPathComponent(".claude").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeDir))
        _ = ClaudeCodeKeychainImport.importCredentials(
            from: Self.validKeychainPayload,
            homeDirectory: tempHome.path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: claudeDir))
    }

    func testWritesFileWith600Permissions() throws {
        _ = ClaudeCodeKeychainImport.importCredentials(
            from: Self.validKeychainPayload,
            homeDirectory: tempHome.path
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: expectedFilePath)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
    }

    func testOverwritesExistingCredentialsFile() throws {
        try FileManager.default.createDirectory(
            at: tempHome.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(to: URL(fileURLWithPath: expectedFilePath))

        _ = ClaudeCodeKeychainImport.importCredentials(
            from: Self.validKeychainPayload,
            homeDirectory: tempHome.path
        )
        let written = try Data(contentsOf: URL(fileURLWithPath: expectedFilePath))
        XCTAssertEqual(written, Self.validKeychainPayload)
    }

    // MARK: - Failure paths

    func testReturnsUnexpectedFormatErrorForUnparseablePayload() {
        let badPayload = Data("not valid json".utf8)
        let result = ClaudeCodeKeychainImport.importCredentials(
            from: badPayload,
            homeDirectory: tempHome.path
        )
        guard case .failure(let error) = result else {
            return XCTFail("Expected failure")
        }
        XCTAssertEqual(error, .unexpectedFormat)
    }

    func testReturnsUnexpectedFormatWhenAccessTokenMissing() {
        let payload = Data(#"{"claudeAiOauth":{"refreshToken":"r","expiresAt":0,"scopes":[]}}"#.utf8)
        let result = ClaudeCodeKeychainImport.importCredentials(
            from: payload,
            homeDirectory: tempHome.path
        )
        guard case .failure(let error) = result else {
            return XCTFail("Expected failure")
        }
        XCTAssertEqual(error, .unexpectedFormat)
    }

    func testDoesNotCreateFileWhenPayloadMalformed() {
        let badPayload = Data("not json".utf8)
        _ = ClaudeCodeKeychainImport.importCredentials(
            from: badPayload,
            homeDirectory: tempHome.path
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedFilePath))
    }

    func testReturnsWriteFailedWhenClaudeDirCannotBeCreated() throws {
        // Pre-create `.claude` as a regular file so createDirectory at that path
        // becomes a no-op (silently swallowed) and the subsequent file write
        // fails because the parent isn't a directory.
        try Data("blocker".utf8).write(to: tempHome.appendingPathComponent(".claude"))

        let result = ClaudeCodeKeychainImport.importCredentials(
            from: Self.validKeychainPayload,
            homeDirectory: tempHome.path
        )
        guard case .failure(let error) = result else {
            return XCTFail("Expected failure")
        }
        guard case .writeFailed = error else {
            return XCTFail("Expected .writeFailed, got \(error)")
        }
    }
}
