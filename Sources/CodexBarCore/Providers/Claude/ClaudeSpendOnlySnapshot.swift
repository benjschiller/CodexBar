import Foundation

extension UsageSnapshot {
    /// The spend-cap window of a Claude seat that reports only an Extra usage budget: no measured quota lane,
    /// no model-scoped weekly window, and a positive cap. nil for any seat with real quota lanes.
    package var claudeSpendOnlyWindow: RateWindow? {
        guard self.primary?.measured == nil,
              self.secondary == nil, self.tertiary == nil,
              self.claudeScopedWeeklyWindow == nil,
              let cost = self.providerCost, cost.limit > 0
        else { return nil }
        return cost.spendLimitWindow
    }
}
