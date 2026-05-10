import SwiftUI

/// Settings panel for testing the unauthenticated UI of each local service
/// without renaming or deleting credential files. Each toggle short-circuits
/// the corresponding service's `hasAccess` to `false` while it stays on, then
/// triggers a re-check + refresh so menu bar rows and the widget cache update
/// immediately. The colored badge next to each row shows the *effective*
/// auth state (what the rest of the UI sees) so the toggle's intent is
/// unambiguous: ON means the override is engaged, the badge tells you what
/// the app is treating the service as.
struct DebugForceUnauthedSection: View {
    @ObservedObject private var debug = DebugSettings.shared
    @StateObject private var claudeCode = ClaudeCodeLocalService.shared
    @StateObject private var codexCli   = CodexCliLocalService.shared
    @StateObject private var cursor     = CursorLocalService.shared

    var body: some View {
        Section("Debug — Force Unauthed (testing only)") {
            row(label: "Claude Code",
                isAuthed: claudeCode.hasAccess,
                isOn: $debug.forceUnauthedClaudeCode) {
                ClaudeCodeLocalService.shared.checkAccess()
                Task { await UsageDataManager.shared.refreshAll() }
            }

            row(label: "Codex CLI",
                isAuthed: codexCli.hasAccess,
                isOn: $debug.forceUnauthedCodexCli) {
                CodexCliLocalService.shared.checkAccess()
                Task { await UsageDataManager.shared.refreshAll() }
            }

            row(label: "Cursor",
                isAuthed: cursor.hasAccess,
                isOn: $debug.forceUnauthedCursor) {
                CursorLocalService.shared.checkAccess()
                Task { await UsageDataManager.shared.refreshAll() }
            }

            Text("Each toggle forces the service's `hasAccess` to false. Real credential files on disk are not touched. The badge shows what the rest of the app currently sees for that service.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func row(label: String, isAuthed: Bool, isOn: Binding<Bool>, onToggle: @escaping () -> Void) -> some View {
        // Underlying flag is `forceUnauthed`. Invert it for the toggle so
        // right/ON reads as "service is allowed to be authed" and left/OFF
        // reads as "forced unauthed".
        let allowAuthed = Binding<Bool>(
            get: { !isOn.wrappedValue },
            set: { isOn.wrappedValue = !$0 }
        )
        HStack(spacing: 8) {
            Text(label)
            Circle()
                .fill(isAuthed ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(isAuthed ? "Authed" : "Unauthed")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Toggle("Authed", isOn: allowAuthed)
                .labelsHidden()
                .onChange(of: isOn.wrappedValue) { _, _ in onToggle() }
        }
    }
}
