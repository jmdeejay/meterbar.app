import Foundation
import Combine

/// Dev-only switches that override the live auth state in the local services.
/// Used to test unauthenticated UI flows without touching real credential
/// files on disk. Persisted in UserDefaults so toggles survive relaunches.
final class DebugSettings: ObservableObject {
    static let shared = DebugSettings()

    @Published var forceUnauthedClaudeCode: Bool {
        didSet { UserDefaults.standard.set(forceUnauthedClaudeCode, forKey: Self.claudeCodeKey) }
    }
    @Published var forceUnauthedCodexCli: Bool {
        didSet { UserDefaults.standard.set(forceUnauthedCodexCli, forKey: Self.codexCliKey) }
    }
    @Published var forceUnauthedCursor: Bool {
        didSet { UserDefaults.standard.set(forceUnauthedCursor, forKey: Self.cursorKey) }
    }

    private static let claudeCodeKey = "debug.forceUnauthed.claudeCode"
    private static let codexCliKey   = "debug.forceUnauthed.codexCli"
    private static let cursorKey     = "debug.forceUnauthed.cursor"

    private init() {
        forceUnauthedClaudeCode = UserDefaults.standard.bool(forKey: Self.claudeCodeKey)
        forceUnauthedCodexCli   = UserDefaults.standard.bool(forKey: Self.codexCliKey)
        forceUnauthedCursor     = UserDefaults.standard.bool(forKey: Self.cursorKey)
    }
}
