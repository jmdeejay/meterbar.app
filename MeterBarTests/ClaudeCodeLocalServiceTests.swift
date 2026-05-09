import XCTest
@testable import MeterBar

final class ClaudeCodeLocalServiceTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-code-local-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempHome.appendingPathComponent(".claude", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempHome = tempHome, FileManager.default.fileExists(atPath: tempHome.path) {
            try FileManager.default.removeItem(at: tempHome)
        }
    }

    // MARK: - Token-bearing credential file

    func testResolvesTokenAndMetadataFromCredentialsFile() throws {
        try writeFixture(#"""
        {
          "claudeAiOauth": {
            "accessToken": "creds-token",
            "refreshToken": "r",
            "expiresAt": 0,
            "scopes": ["user:profile"],
            "subscriptionType": "max_5x",
            "rateLimitTier": "tier-2"
          }
        }
        """#, relativePath: ".claude/.credentials.json")

        let snapshot = ClaudeCodeCredentialResolver.resolveSnapshot(homeDirectory: tempHome.path)

        XCTAssertEqual(snapshot?.token, "creds-token")
        XCTAssertEqual(snapshot?.subscriptionType, "max_5x")
        XCTAssertEqual(snapshot?.rateLimitTier, "tier-2")
    }

    // MARK: - Metadata-only `.claude.json`

    func testEnrichesMissingMetadataFromClaudeJson() throws {
        // Credentials file supplies the token but no subscription metadata.
        try writeFixture(#"""
        {
          "claudeAiOauth": {
            "accessToken": "creds-token",
            "refreshToken": "r",
            "expiresAt": 0,
            "scopes": []
          }
        }
        """#, relativePath: ".claude/.credentials.json")

        // .claude.json carries the subscription/tier metadata only.
        try writeFixture(#"""
        {
          "oauthAccount": {
            "subscriptionType": "max_20x",
            "rateLimitTier": "premium"
          }
        }
        """#, relativePath: ".claude/.claude.json")

        let snapshot = ClaudeCodeCredentialResolver.resolveSnapshot(homeDirectory: tempHome.path)

        XCTAssertEqual(snapshot?.token, "creds-token")
        XCTAssertEqual(snapshot?.subscriptionType, "max_20x")
        XCTAssertEqual(snapshot?.rateLimitTier, "premium")
    }

    func testClaudeJsonAloneCannotAuthenticate() throws {
        // .claude.json carries metadata but no token; no other source available.
        try writeFixture(#"""
        {
          "oauthAccount": {
            "subscriptionType": "pro",
            "rateLimitTier": "tier-1"
          }
        }
        """#, relativePath: ".claude/.claude.json")

        XCTAssertNil(ClaudeCodeCredentialResolver.resolveSnapshot(homeDirectory: tempHome.path))
    }

    // MARK: - settings.json env override

    func testResolvesTokenFromSettingsEnvOverride() throws {
        try writeFixture(#"""
        {
          "env": {
            "ANTHROPIC_AUTH_TOKEN": "env-token"
          }
        }
        """#, relativePath: ".claude/settings.json")

        let snapshot = ClaudeCodeCredentialResolver.resolveSnapshot(homeDirectory: tempHome.path)

        XCTAssertEqual(snapshot?.token, "env-token")
        XCTAssertNil(snapshot?.subscriptionType)
        XCTAssertNil(snapshot?.rateLimitTier)
    }

    func testCredentialsFileTakesPrecedenceOverSettingsEnvToken() throws {
        try writeFixture(#"""
        {
          "claudeAiOauth": {
            "accessToken": "creds-token",
            "refreshToken": "r",
            "expiresAt": 0,
            "scopes": []
          }
        }
        """#, relativePath: ".claude/.credentials.json")

        try writeFixture(#"""
        {
          "env": {
            "ANTHROPIC_AUTH_TOKEN": "env-token"
          }
        }
        """#, relativePath: ".claude/settings.json")

        let snapshot = ClaudeCodeCredentialResolver.resolveSnapshot(homeDirectory: tempHome.path)

        XCTAssertEqual(snapshot?.token, "creds-token")
    }

    // MARK: - Failure-closed behaviour

    func testReturnsNilWhenNoLocalFilesPresent() {
        XCTAssertNil(ClaudeCodeCredentialResolver.resolveSnapshot(homeDirectory: tempHome.path))
    }

    func testReturnsNilForUnparseableCredentialFile() throws {
        try writeFixture("this is not json", relativePath: ".claude/.credentials.json")

        XCTAssertNil(ClaudeCodeCredentialResolver.resolveSnapshot(homeDirectory: tempHome.path))
    }

    func testReturnsNilWhenCredentialsFileMissingAccessToken() throws {
        try writeFixture(#"""
        {
          "claudeAiOauth": {
            "refreshToken": "r",
            "expiresAt": 0,
            "scopes": []
          }
        }
        """#, relativePath: ".claude/.credentials.json")

        XCTAssertNil(ClaudeCodeCredentialResolver.resolveSnapshot(homeDirectory: tempHome.path))
    }

    // MARK: - Helpers

    private func writeFixture(_ contents: String, relativePath: String) throws {
        let url = tempHome.appendingPathComponent(relativePath)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
