import Foundation
import SwiftUI

struct UsageLimit: Codable, Equatable, Identifiable {
    let id: UUID
    /// Short label for tight UI.
    let compactLabel: String
    /// Long label for expanded UI.
    let verboseLabel: String
    let used: Double
    let total: Double
    let resetTime: Date?

    init(
        compactLabel: String,
        verboseLabel: String,
        used: Double,
        total: Double,
        resetTime: Date? = nil
    ) {
        self.id = UUID()
        self.compactLabel = compactLabel
        self.verboseLabel = verboseLabel
        self.used = used
        self.total = total
        self.resetTime = resetTime
    }

    var percentage: Double {
        guard total > 0 else { return 0 }
        return min(100, max(0, (used / total) * 100))
    }

    var remaining: Double {
        return max(0, total - used)
    }

    var isNearLimit: Bool {
        return percentage >= 80
    }

    var isAtLimit: Bool {
        return percentage >= 100
    }

    var statusColor: UsageStatus {
        if isAtLimit {
            return .critical
        } else if isNearLimit {
            return .warning
        } else {
            return .good
        }
    }
}

enum UsageStatus {
    case good
    case warning
    case critical

    var color: Color {
        switch self {
        case .good:     return Color(red:  52/255, green: 199/255, blue:  89/255) // ~system green
        case .warning:  return Color(red: 255/255, green: 149/255, blue:   0/255) // ~system orange
        case .critical: return Color(red: 255/255, green:  59/255, blue:  48/255) // ~system red
        }
    }
}
