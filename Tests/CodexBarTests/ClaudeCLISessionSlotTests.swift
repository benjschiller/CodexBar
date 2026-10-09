import Foundation
import Testing
@testable import CodexBarCore

/// The CLI never invents a session: Session comes only from a Current session row, so weekly-only and
/// per-model-only panels load without one.
struct ClaudeCLISessionSlotTests {
    private typealias Fixtures = ClaudeCLIUsageFixtures

    @Test
    func `weekly only screen has no session and keeps weekly`() async throws {
        let text = Fixtures.screen(quota: Fixtures.weeklyQuota, credits: nil)
        let status = try ClaudeStatusProbe.parse(text: text)
        let usage = try await Fixtures.loadUsage(status)

        #expect(status.sessionPercentLeft == nil)
        #expect(status.weeklyPercentLeft == 88)
        #expect(usage.primary == nil)
        #expect(usage.secondary?.usedPercent == 12)
        #expect(usage.secondary?.windowMinutes == 7 * 24 * 60)
        #expect(usage.providerCost == nil)
    }

    @Test
    func `per model only screen has no session and keeps the scoped window`() async throws {
        let text = Fixtures.screen(quota: Fixtures.modelOnlyQuota, credits: nil)
        let status = try ClaudeStatusProbe.parse(text: text)
        let usage = try await Fixtures.loadUsage(status)

        #expect(status.sessionPercentLeft == nil)
        #expect(status.weeklyPercentLeft == nil)
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.extraRateWindows.map(\.title) == ["Fable only"])
        #expect(usage.extraRateWindows.first?.window.usedPercent == 7)
    }

    @Test
    func `a garbled session label still gets the order based session fallback`() throws {
        let snapshot = try ClaudeStatusProbe.parse(text: """
        Settings:  Status   Config   Usage  (tab to cycle)
        Curretsession
        ███████▌15% used
        Resets 11:30pm (Asia/Calcutta)

        Current week (all models)
        █▌                                                 3% used
        """)

        #expect(snapshot.sessionPercentLeft == 85)
        #expect(snapshot.weeklyPercentLeft == 97)
    }

    @Test
    func `a weekly row is not a session label`() throws {
        let snapshot = try ClaudeStatusProbe.parse(text: """
        Settings:  Status   Config   Usage  (tab to cycle)
        Current week (all models)
        █▌                                                 3% used
        Resets Feb 12 at 1:30pm (Asia/Calcutta)

        Current week (Sonnet only)
        ▌                                                  1% used
        Resets Feb 12 at 1:30pm (Asia/Calcutta)
        """)

        #expect(snapshot.sessionPercentLeft == nil)
        #expect(snapshot.weeklyPercentLeft == 97)
        #expect(snapshot.opusPercentLeft == 99)
    }

    @Test
    func `capture completes on a quota panel without waiting for a session row`() {
        let complete = [
            Fixtures.screen(quota: Fixtures.weeklyQuota, credits: nil),
            Fixtures.screen(quota: Fixtures.modelOnlyQuota, credits: nil),
            Fixtures.screen(quota: Fixtures.sessionAndWeeklyQuota, credits: nil),
            "You are currently using your subscription to power your Claude Code usage",
        ]
        for text in complete {
            #expect(ClaudeStatusProbe.usageCaptureIsComplete(Fixtures.normalized(text)))
        }

        let incomplete = [
            "Settings:  Status   Config   Usage  (tab to cycle)\nLoading usage data…\nEsc to cancel",
            Fixtures.screen(credits: nil),
            "Current session\nCurrent week (all models)",
        ]
        for text in incomplete {
            #expect(!ClaudeStatusProbe.usageCaptureIsComplete(Fixtures.normalized(text)))
        }
    }

    @Test
    func `a weekly only screen beside a loading remnant is not still loading`() throws {
        let text = "Settings:  Status   Config   Usage  (tab to cycle)\nLoading usage data…\n"
            + Fixtures.screen(quota: Fixtures.weeklyQuota, credits: nil)
        try ClaudeStatusProbe.validateUsageBeforeStatusProbe(text)
        #expect(try ClaudeStatusProbe.parse(text: text).weeklyPercentLeft == 88)
    }
}
