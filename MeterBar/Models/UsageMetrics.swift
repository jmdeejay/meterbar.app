import Foundation

struct UsageMetrics: Codable, Identifiable {
    let id: UUID
    let service: ServiceType
    /// Ordered list of bars to display.
    let limits: [UsageLimit]
    let lastUpdated: Date

    init(
        service: ServiceType,
        limits: [UsageLimit] = [],
        lastUpdated: Date = Date()
    ) {
        self.id = UUID()
        self.service = service
        self.limits = limits
        self.lastUpdated = lastUpdated
    }

    var overallStatus: UsageStatus {
        guard !limits.isEmpty else { return .good }
        if limits.contains(where: { $0.isAtLimit }) {
            return .critical
        } else if limits.contains(where: { $0.isNearLimit }) {
            return .warning
        } else {
            return .good
        }
    }

    var hasData: Bool { !limits.isEmpty }
}
