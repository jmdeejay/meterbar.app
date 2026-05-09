import Foundation

/// Failure modes for the keychain → file bridge. Surfaced as a typed error so tests
/// can pattern-match without parsing strings.
enum ClaudeCodeImportError: Error, Equatable {
    case unexpectedFormat
    case writeFailed(filePath: String, message: String)
}

/// Pure parse-and-write half of `ClaudeCodeLocalService.importCredentialsFromKeychain`.
/// The Keychain read happens in the service (it triggers macOS's consent UI and can't
/// run in unit tests); this type takes the resulting `Data` and a home directory and
/// performs the validation + atomic write that we *can* test.
enum ClaudeCodeKeychainImport {
    static func importCredentials(
        from keychainData: Data,
        homeDirectory: String
    ) -> Result<Void, ClaudeCodeImportError> {
        guard ClaudeCodeCredentialResolver.parseCredentialsFile(data: keychainData) != nil else {
            return .failure(.unexpectedFormat)
        }

        let claudeDir = "\(homeDirectory)/.claude"
        let filePath  = "\(claudeDir)/.credentials.json"

        try? FileManager.default.createDirectory(
            atPath: claudeDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        do {
            try keychainData.write(to: URL(fileURLWithPath: filePath), options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: filePath
            )
            return .success(())
        } catch {
            return .failure(.writeFailed(filePath: filePath, message: error.localizedDescription))
        }
    }
}
