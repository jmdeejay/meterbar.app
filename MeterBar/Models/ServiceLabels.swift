import Foundation

/// Label resolver shared between the main app and the widget extension. Both
/// targets define their own `ServiceType` enum (the widget's is a 3-case subset
/// of the app's 5 cases), so callers pass the rawValue ID instead of an enum
/// instance — that way one implementation services both targets without forcing
/// a single shared enum.
enum ServiceLabels {
    static func compactDisplayName(for serviceID: String) -> String {
        switch serviceID {
        case "Claude Code": return "Claude"
        case "Codex CLI":   return "OpenAI"
        case "Cursor":      return "Cursor"
        default:            return serviceID
        }
    }

    static func sessionLabel(for serviceID: String, verbose: Bool) -> String {
        switch serviceID {
        case "Claude Code": return verbose ? "Session (5h)" : "S"
        case "Codex CLI":   return verbose ? "Session (5h)" : "S"
        case "Cursor":      return verbose ? "On-Demand"    : "OD"
        default:            return ""
        }
    }

    static func weeklyLabel(for serviceID: String, verbose: Bool) -> String {
        switch serviceID {
        case "Claude Code": return verbose ? "All Models (7d)" : "W"
        case "Codex CLI":   return verbose ? "Weekly"          : "W"
        case "Cursor":      return verbose ? "Monthly"         : "M"
        default:            return ""
        }
    }

    static func codeReviewLabel(for serviceID: String, verbose: Bool) -> String {
        switch serviceID {
        case "Claude Code":         return verbose ? "Sonnet (7d)" : "Sn"
        case "Codex CLI", "Cursor": return verbose ? "Code Review" : "CR"
        default:                    return ""
        }
    }
}
