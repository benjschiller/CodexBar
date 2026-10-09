import Foundation
import Testing
@testable import CodexBarCore

/// The CLI reads its Usage credits block as the spend cap, defensively: the panel layout is not a contract, so any
/// mismatch yields no spend cap and leaves the rest of the parse untouched.
struct ClaudeCLISpendCapTests {
    private typealias Fixtures = ClaudeCLIUsageFixtures

    // MARK: - Usage credits

    @Test
    func `usage credits screen reads the spend cap and no session or weekly`() throws {
        let snapshot = try ClaudeStatusProbe.parse(text: Fixtures.screen())

        #expect(snapshot.sessionPercentLeft == nil)
        #expect(snapshot.weeklyPercentLeft == nil)
        #expect(snapshot.opusPercentLeft == nil)
        #expect(snapshot.extraRateWindows.isEmpty)
        #expect(snapshot.spendCap == ClaudeCLISpendCap(used: 420, limit: 1000, currencyCode: "USD"))
    }

    @Test
    func `usage credits screen builds the spend cap like OAuth and Web`() async throws {
        let status = try ClaudeStatusProbe.parse(text: Fixtures.screen())
        let usage = try await Fixtures.loadUsage(status)

        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.opus == nil)
        let cost = try #require(usage.providerCost)
        #expect(cost.used == 420)
        #expect(cost.limit == 1000)
        #expect(cost.currencyCode == "USD")
        #expect(cost.period == "Spend limit")
        #expect(cost.resetsAtIsInferred == true)
        // The CLI prints the reset in local time; the rollover rule is the one every source shares.
        let rollover = try #require(ClaudeSpendRollover(now: usage.updatedAt))
        #expect(cost.resetsAt == rollover.resetsAt)
        #expect(cost.windowMinutes == rollover.windowMinutes)

        let oauth = try ClaudeUsageFetcher._mapOAuthUsageForTesting(
            Data(#"""
            {"extra_usage": {"is_enabled": true, "monthly_limit": 100000, "used_credits": 42000,
             "currency": "USD"}}
            """#.utf8),
            now: usage.updatedAt)
        #expect(cost == oauth.providerCost)

        let web = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(
            Data(#"""
            {"five_hour": null, "extra_usage": {"monthly_limit": 100000, "used_credits": 42000}}
            """#.utf8),
            now: usage.updatedAt)
        let webCost = try #require(web.extraUsageCost)
        #expect(cost.used == webCost.used)
        #expect(cost.limit == webCost.limit)
        #expect(cost.resetsAt == webCost.resetsAt)
        #expect(cost.windowMinutes == webCost.windowMinutes)

        let snapshot = ClaudeOAuthFetchStrategy._snapshotForTesting(from: usage)
        #expect(snapshot.primary == nil)
        #expect(snapshot.claudeSpendOnlyWindow?.usedPercent == 42)
    }

    @Test
    func `usage credits beside quota rows label the cap a monthly cap and keep the quota`() async throws {
        let status = try ClaudeStatusProbe.parse(text: Fixtures.screen(quota: Fixtures.sessionAndWeeklyQuota))
        let usage = try await Fixtures.loadUsage(status)

        #expect(status.sessionPercentLeft == 87)
        #expect(status.weeklyPercentLeft == 98)
        #expect(usage.primary?.usedPercent == 13)
        #expect(usage.secondary?.usedPercent == 2)
        #expect(usage.providerCost?.period == "Monthly cap")
        #expect(usage.providerCost?.used == 420)
    }

    @Test
    func `insights percentages never become session or spend data`() throws {
        let snapshot = try ClaudeStatusProbe.parse(text: Fixtures.screen())

        #expect(snapshot.sessionPercentLeft == nil)
        #expect(snapshot.weeklyPercentLeft == nil)
        #expect(snapshot.spendCap?.used == 420)
        let insightsOnly = Fixtures.screen(credits: nil)
        let error = #expect(throws: ClaudeStatusProbeError.self) {
            try ClaudeStatusProbe.parse(text: insightsOnly)
        }
        #expect(error?.localizedDescription == "Could not parse Claude usage: Missing Current session.")
    }

    // MARK: - Layout drift

    private static let driftedBlocks: [String] = [
        // No spend line.
        "  Usage credits\n  █████████████████████                              42% used",
        // Garbled amounts.
        "  Usage credits\n  $4x0.00 / $1,000.00 spent",
        "  Usage credits\n  $420.00 / $1,0,00 spent",
        "  Usage credits\n  $420.00 / $ spent",
        "  Usage credits\n  $420.00 / spent",
        // Other currencies and look-alike symbols.
        "  Usage credits\n  €420.00 / €1,000.00 spent",
        "  Usage credits\n  £420.00 / £1,000.00 spent",
        "  Usage credits\n  A$420.00 / A$1,000.00 spent",
        "  Usage credits\n  CA$420.00 / CA$1,000.00 spent",
        "  Usage credits\n  $420.00 / €1,000.00 spent",
        // Negative, zero, and absurd values.
        "  Usage credits\n  -$420.00 / $1,000.00 spent",
        "  Usage credits\n  $420.00 / -$1,000.00 spent",
        "  Usage credits\n  $420.00 / $0.00 spent",
        "  Usage credits\n  $0.00 / $0.00 spent",
        "  Usage credits\n  $420.00 / $\(String(repeating: "9", count: 400)) spent",
        "  Usage credits\n  $\(String(repeating: "9", count: 20)) / $1,000.00 spent",
        // Header absent.
        "  █████████████████████                              42% used\n  $420.00 / $1,000.00 spent",
        "  Credits\n  $420.00 / $1,000.00 spent",
        // The block is too far below its header to belong to it.
        "  Usage credits\n\n\n\n\n\n\n\n\n  $420.00 / $1,000.00 spent",
    ]

    @Test(arguments: Self.driftedBlocks)
    func `a drifted usage credits block yields no spend cap`(block: String) {
        #expect(ClaudeCLISpendCapParser.parse(block) == nil)
        #expect(ClaudeCLISpendCapParser.parse(Fixtures.screen(credits: block)) == nil)
    }

    @Test(arguments: Self.driftedBlocks)
    func `a drifted usage credits block leaves a quota parse untouched`(block: String) throws {
        let snapshot = try ClaudeStatusProbe.parse(text: Fixtures.screen(
            quota: Fixtures.sessionAndWeeklyQuota,
            credits: block))

        #expect(snapshot.sessionPercentLeft == 87)
        #expect(snapshot.weeklyPercentLeft == 98)
        #expect(snapshot.spendCap == nil)
    }

    @Test(arguments: Self.driftedBlocks)
    func `a drifted usage credits block alone has nothing usable`(block: String) {
        #expect(throws: ClaudeStatusProbeError.self) {
            try ClaudeStatusProbe.parse(text: Fixtures.screen(credits: block))
        }
    }

    @Test
    func `box characters and extra whitespace around the block still parse`() {
        let blocks = [
            "│  Usage credits                         │\n│  ███   42% used                        │\n"
                + "│  $420.00 / $1,000.00 spent · Resets Nov 1 (America/New_York)  │",
            "   USAGE   CREDITS\n\n   $ 420.00   /   $ 1,000.00   spent",
            "Usage credits\t$420 / $1000 spent",
            "  Usage credits: $420.00 / $1,000.00 spent",
        ]
        for block in blocks {
            let cap = ClaudeCLISpendCapParser.parse(block)
            #expect(cap == ClaudeCLISpendCap(used: 420, limit: 1000, currencyCode: "USD"))
        }
    }

    @Test
    func `the newest usage credits block wins when a plain capture holds several frames`() {
        let text = """
          Usage credits
          $100.00 / $1,000.00 spent
          Usage credits
          $420.00 / $1,000.00 spent
        """
        #expect(ClaudeCLISpendCapParser.parse(text)?.used == 420)
    }

    @Test
    func `empty and binary input never produce a spend cap`() {
        #expect(ClaudeCLISpendCapParser.parse("") == nil)
        #expect(ClaudeCLISpendCapParser.parse("\u{0}\u{1b}[2J\u{7f}") == nil)
        #expect(ClaudeCLISpendCapParser.parse("Usage credits") == nil)
        #expect(ClaudeCLISpendCapParser.parse("Usage credits\n$") == nil)
    }

    @Test
    func `capture completes on the usage credits block and not on its header alone`() {
        #expect(ClaudeStatusProbe.usageCaptureIsComplete(Fixtures.normalized(Fixtures.screen())))
        #expect(!ClaudeStatusProbe.usageCaptureIsComplete(Fixtures.normalized(Fixtures.screen(credits: nil))))
        #expect(!ClaudeStatusProbe.usageCaptureIsComplete(
            Fixtures.normalized("Usage credits\n█████ 42% used")))
    }

    @Test
    func `a spend only screen is relevant and not still loading`() throws {
        #expect(ClaudeStatusProbe.usageOutputLooksRelevant(Fixtures.screen()))
        #expect(!ClaudeStatusProbe.usageOutputLooksRelevant(Fixtures.screen(credits: nil)))
        try ClaudeStatusProbe.validateUsageBeforeStatusProbe(Fixtures.screen())

        let loadingRemnant = "Settings:  Status   Config   Usage  (tab to cycle)\nLoading usage data…\n"
            + Fixtures.screen()
        try ClaudeStatusProbe.validateUsageBeforeStatusProbe(loadingRemnant)
        #expect(try ClaudeStatusProbe.parse(text: loadingRemnant).spendCap?.limit == 1000)

        #expect(throws: ClaudeStatusProbeError.self) {
            try ClaudeStatusProbe.validateUsageBeforeStatusProbe(
                "Settings:  Status   Config   Usage  (tab to cycle)\nLoading usage data…\nEsc to cancel")
        }
    }

    // MARK: - Web extras

    @Test
    func `web extras never double up a CLI spend cap`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cli = ProviderCostSnapshot(
            used: 420,
            limit: 1000,
            currencyCode: "USD",
            period: "Spend limit",
            updatedAt: now)
        let web = ProviderCostSnapshot(
            used: 421,
            limit: 1000,
            currencyCode: "USD",
            period: "Monthly cap",
            balance: 55,
            updatedAt: now)

        let merged = try #require(ClaudeUsageFetcher._mergeProviderCostForTesting(primary: cli, web: web))
        #expect(merged.used == 420)
        #expect(merged.limit == 1000)
        #expect(merged.period == "Spend limit")
        #expect(merged.balance == 55)

        let withoutBalance = ProviderCostSnapshot(
            used: 421,
            limit: 1000,
            currencyCode: "USD",
            period: "Monthly cap",
            updatedAt: now)
        #expect(ClaudeUsageFetcher._mergeProviderCostForTesting(primary: cli, web: withoutBalance) == cli)
        #expect(ClaudeUsageFetcher._mergeProviderCostForTesting(primary: nil, web: web) == web)
    }
}
