import Foundation
import Testing
@testable import CodexBarCore

/// Session (`primary`) holds only a real 5-hour window, whichever source supplied the usage. A source that reports
/// no session leaves it nil and keeps weekly, model-specific, scoped, and spend data in their own slots.
struct ClaudeSessionSlotTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    enum Source: CaseIterable {
        case oauth
        case web

        func usage(_ payload: String) throws -> ClaudeUsageSnapshot {
            let data = Data(payload.utf8)
            switch self {
            case .oauth:
                return try ClaudeUsageFetcher._mapOAuthUsageForTesting(data, now: ClaudeSessionSlotTests.now)
            case .web:
                let parsed = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(
                    data,
                    now: ClaudeSessionSlotTests.now)
                return try ClaudeUsageFetcher.mapWebUsage(
                    parsed,
                    includeAccountIdentity: false,
                    now: ClaudeSessionSlotTests.now)
            }
        }
    }

    private static let weeklyOnly = """
    {"five_hour": null, "seven_day": {"utilization": 42, "resets_at": "2027-01-20T00:00:00Z"}}
    """

    private static let modelOnly = """
    {"five_hour": null, "seven_day": null, "seven_day_sonnet": {"utilization": 17}}
    """

    private static let scopedOnly = """
    {"five_hour": null, "seven_day": null, "limits": [
      {"kind": "weekly_scoped", "group": "weekly", "percent": 6,
       "resets_at": "2027-01-20T09:00:00Z",
       "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": true}
    ]}
    """

    private static let spendOnly = """
    {"five_hour": null, "seven_day": null,
     "extra_usage": {"is_enabled": true, "monthly_limit": 10000, "used_credits": 2500, "currency": "USD"}}
    """

    private static let nothingUsable = [
        #"{}"#,
        #"{"five_hour": null, "seven_day": null}"#,
        #"{"five_hour": {"resets_at": "2027-01-15T12:00:00Z"}, "seven_day": null}"#,
        #"{"five_hour": null, "extra_usage": {"is_enabled": true, "monthly_limit": 0, "used_credits": 0}}"#,
    ]

    @Test(arguments: Source.allCases)
    func `weekly only payload has no session and keeps weekly`(source: Source) throws {
        let usage = try source.usage(Self.weeklyOnly)

        #expect(usage.primary == nil)
        #expect(usage.secondary?.usedPercent == 42)
        #expect(usage.secondary?.windowMinutes == 7 * 24 * 60)
        #expect(usage.opus == nil)
        #expect(usage.providerCost == nil)
    }

    @Test(arguments: Source.allCases)
    func `model specific only payload has no session or weekly`(source: Source) throws {
        let usage = try source.usage(Self.modelOnly)

        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.opus?.usedPercent == 17)
    }

    @Test(arguments: Source.allCases)
    func `scoped only payload loads without a session weekly or spend cap`(source: Source) throws {
        let usage = try source.usage(Self.scopedOnly)

        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.opus == nil)
        #expect(usage.providerCost == nil)
        let fable = try #require(usage.extraRateWindows.first { $0.id == "claude-weekly-scoped-fable" })
        #expect(fable.window.usedPercent == 6)

        let snapshot = ClaudeOAuthFetchStrategy._snapshotForTesting(from: usage)
        #expect(snapshot.primary == nil)
        #expect(snapshot.claudeScopedWeeklyWindow?.window.usedPercent == 6)
    }

    @Test(arguments: Source.allCases)
    func `spend only payload has no session and keeps the spend cap`(source: Source) throws {
        let usage = try source.usage(Self.spendOnly)

        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.opus == nil)
        let cost = try #require(usage.providerCost)
        #expect(cost.used == 25)
        #expect(cost.limit == 100)
        #expect(cost.currencyCode == "USD")
        #expect(cost.resetsAtIsInferred == true)

        let snapshot = ClaudeOAuthFetchStrategy._snapshotForTesting(from: usage)
        #expect(snapshot.primary == nil)
        #expect(snapshot.claudeSpendOnlyWindow?.usedPercent == 25)
    }

    @Test(arguments: Source.allCases, Self.nothingUsable)
    func `payload with nothing usable throws`(source: Source, payload: String) {
        #expect(throws: ClaudeUsageError.self) {
            try source.usage(payload)
        }
    }

    @Test
    func `OAuth ignores a disabled extra usage block`() {
        #expect(throws: ClaudeUsageError.self) {
            try Source.oauth.usage("""
            {"five_hour": null, "extra_usage": {"is_enabled": false, "monthly_limit": 10000, "used_credits": 2500}}
            """)
        }
    }

    @Test(arguments: Source.allCases)
    func `a real five hour window is the session and weekly stays separate`(source: Source) throws {
        let usage = try source.usage("""
        {"five_hour": {"utilization": 11, "resets_at": "2027-01-15T12:00:00Z"},
         "seven_day": {"utilization": 42, "resets_at": "2027-01-20T00:00:00Z"}}
        """)

        #expect(usage.primary?.usedPercent == 11)
        #expect(usage.primary?.windowMinutes == 5 * 60)
        #expect(usage.secondary?.usedPercent == 42)
    }

    @Test(arguments: Source.allCases)
    func `an idle five hour window stays the session instead of the weekly`(source: Source) throws {
        let usage = try source.usage("""
        {"five_hour": {"utilization": 0}, "seven_day": {"utilization": 42}}
        """)

        #expect(usage.primary?.usedPercent == 0)
        #expect(usage.primary?.windowMinutes == 5 * 60)
        #expect(usage.secondary?.usedPercent == 42)
    }

    @Test
    func `OAuth never shows seven day oauth apps and rejects a payload that has only that window`() throws {
        #expect(throws: ClaudeUsageError.self) {
            try ClaudeUsageFetcher._mapOAuthUsageForTesting(
                Data(#"{"five_hour": null, "seven_day_oauth_apps": {"utilization": 9}}"#.utf8),
                now: Self.now)
        }

        let alongside = try ClaudeUsageFetcher._mapOAuthUsageForTesting(
            Data(#"""
            {"five_hour": {"utilization": 3}, "seven_day_oauth_apps": {"utilization": 9}}
            """#.utf8),
            now: Self.now)
        #expect(alongside.primary?.usedPercent == 3)
        #expect(alongside.secondary == nil)
        #expect(alongside.opus == nil)

        let withWeekly = try ClaudeUsageFetcher._mapOAuthUsageForTesting(
            Data(#"""
            {"five_hour": {"utilization": 3}, "seven_day": {"utilization": 42},
             "seven_day_oauth_apps": {"utilization": 9}}
            """#.utf8),
            now: Self.now)
        #expect(withWeekly.secondary?.usedPercent == 42)
        #expect(withWeekly.extraRateWindows.isEmpty)
    }

    @Test
    func `OAuth spend only payload labels the cap as a spend limit and a quota payload as a monthly cap`() throws {
        let spendOnly = try Source.oauth.usage(Self.spendOnly)
        #expect(spendOnly.providerCost?.period == "Spend limit")

        let withQuota = try Source.oauth.usage("""
        {"five_hour": {"utilization": 3}, "extra_usage": {"is_enabled": true, "monthly_limit": 10000,
         "used_credits": 2500, "currency": "USD"}}
        """)
        #expect(withQuota.providerCost?.period == "Monthly cap")
    }

    @Test
    func `sources agree on the shape of every payload they can both read`() throws {
        for payload in [Self.weeklyOnly, Self.modelOnly, Self.scopedOnly, Self.spendOnly] {
            let oauth = try Source.oauth.usage(payload)
            let web = try Source.web.usage(payload)

            #expect(oauth.primary == nil)
            #expect(web.primary == nil)
            #expect(oauth.secondary?.usedPercent == web.secondary?.usedPercent)
            #expect(oauth.opus?.usedPercent == web.opus?.usedPercent)
            #expect(oauth.extraRateWindows.map(\.id) == web.extraRateWindows.map(\.id))
            #expect(oauth.providerCost?.used == web.providerCost?.used)
            #expect(oauth.providerCost?.limit == web.providerCost?.limit)
        }
    }
}
