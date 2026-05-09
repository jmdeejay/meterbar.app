import Foundation

/// Deduplicates limit-threshold notifications so a single (service × limit × tier) key
/// fires at most once per "limit window". The window is identified by the limit's
/// `resetTime`: when the API returns a fresh reset time, the window has advanced and a
/// new notification is allowed. When the reset time is unknown (`nil`), the window can't
/// be identified so we conservatively notify once and stay silent for that key until a
/// known window boundary appears.
struct NotificationDeduper {
    enum Tier: Hashable {
        case warning
        case reached
    }

    struct Key: Hashable {
        let service: ServiceType
        let limitName: String
        let tier: Tier
    }

    private struct Record {
        let resetTime: Date?
    }

    private var records: [Key: Record] = [:]

    /// Decides whether a notification should be sent for this key. Records the decision
    /// internally so subsequent calls in the same window are skipped.
    mutating func shouldNotify(key: Key, currentResetTime: Date?) -> Bool {
        if let prev = records[key] {
            // Re-fire only when both windows have known reset times AND they differ.
            // Anything else (either side nil, or same date) is treated as the same window.
            if let prevReset = prev.resetTime,
               let currentReset = currentResetTime,
               prevReset != currentReset {
                records[key] = Record(resetTime: currentResetTime)
                return true
            }
            return false
        }
        records[key] = Record(resetTime: currentResetTime)
        return true
    }
}
