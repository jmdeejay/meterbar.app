import Foundation

/// Resolves the real user home directory. `FileManager.default.homeDirectoryForCurrentUser`
/// returns the sandbox container path (`~/Library/Containers/<bundle-id>/Data`) for
/// sandboxed apps, which is wrong any time we want to read configuration written by
/// another tool (Claude Code, Codex CLI, Cursor) into the user's actual home. Calling
/// `getpwuid(getuid())` returns the real `pw_dir` regardless of sandbox state.
enum RealHome {
    static var path: String {
        if let pw = getpwuid(getuid()) {
            return String(cString: pw.pointee.pw_dir)
        }
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            return home
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }
}
