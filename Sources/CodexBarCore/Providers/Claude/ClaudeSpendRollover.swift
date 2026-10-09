import Foundation

/// Claude's usage API sends no spend reset; Anthropic documents monthly spend resetting at 00:00 UTC on the 1st
/// (platform.claude.com/docs/en/manage-claude/spend-limits-api).
struct ClaudeSpendRollover: Equatable, Sendable {
    let resetsAt: Date
    let windowMinutes: Int?

    init?(now: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        guard let resetsAt = calendar.dateInterval(of: .month, for: now)?.end else { return nil }
        self.resetsAt = resetsAt
        self.windowMinutes = ProviderPaceCapability.calendarMonthResetWindow.resolvedResetWindowForPace(RateWindow(
            usedPercent: 0,
            windowMinutes: ProviderPaceCapability.monthlyWindowSentinelMinutes,
            resetsAt: resetsAt,
            resetDescription: nil)).windowMinutes
    }
}
