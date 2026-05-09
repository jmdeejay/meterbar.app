import AppIntents
import WidgetKit
import Foundation

@available(macOS 14.0, *)
struct RefreshUsageIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh MeterBar Usage"
    static var description = IntentDescription("Re-fetch usage metrics from each connected service.")

    func perform() async throws -> some IntentResult {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(MeterBarSignals.widgetRefreshRequested),
            nil, nil, true
        )
        WidgetCenter.shared.reloadTimelines(ofKind: "UsageWidget")
        return .result()
    }
}
