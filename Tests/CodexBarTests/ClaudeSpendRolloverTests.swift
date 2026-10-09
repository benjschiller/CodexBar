import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeSpendRolloverTests {
    struct MonthSample: Sendable {
        let now: String
        let resetsAt: String
        let days: Int
    }

    private static let overageJSON = Data("""
    {
      "monthly_credit_limit": 2000,
      "currency": "USD",
      "used_credits": 250,
      "is_enabled": true
    }
    """.utf8)

    private static func date(_ iso: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: iso))
    }

    @Test
    func `enterprise spend limit rolls over at the next UTC month start`() throws {
        let now = try Self.date("2026-10-07T12:00:00Z")
        let rollover = try #require(ClaudeSpendRollover(now: now))
        let expectedReset = try Self.date("2026-11-01T00:00:00Z")

        #expect(rollover.resetsAt == expectedReset)

        let web = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(
            Data("""
            {
              "five_hour": null,
              "seven_day": null,
              "extra_usage": { "monthly_limit": 20000, "used_credits": 1250 }
            }
            """.utf8),
            now: now)
        let cost = try #require(web.extraUsageCost)
        #expect(cost.resetsAt == expectedReset)
        #expect(cost.windowMinutes == 31 * 24 * 60)
        #expect(cost.updatedAt == now)
    }

    @Test(arguments: [
        MonthSample(now: "2026-02-10T08:30:00Z", resetsAt: "2026-03-01T00:00:00Z", days: 28),
        MonthSample(now: "2026-04-15T00:00:01Z", resetsAt: "2026-05-01T00:00:00Z", days: 30),
        MonthSample(now: "2026-10-07T12:00:00Z", resetsAt: "2026-11-01T00:00:00Z", days: 31),
        MonthSample(now: "2028-02-29T23:59:59Z", resetsAt: "2028-03-01T00:00:00Z", days: 29),
    ])
    func `monthly cap rollover uses the real month length`(sample: MonthSample) throws {
        let now = try Self.date(sample.now)
        let expectedReset = try Self.date(sample.resetsAt)
        let cost = try #require(ClaudeWebAPIFetcher._parseOverageSpendLimitForTesting(Self.overageJSON, now: now))

        #expect(cost.period == "Monthly cap")
        #expect(cost.resetsAt == expectedReset)
        #expect(cost.windowMinutes == sample.days * 24 * 60)
    }

    @Test
    func `rollover at exactly midnight UTC on the first moves to the following month`() throws {
        let midnight = try Self.date("2026-10-01T00:00:00Z")
        let beforeMidnight = try Self.date("2026-09-30T23:59:59Z")
        let newYearsEve = try Self.date("2026-12-31T23:59:59Z")

        let atMidnight = try #require(ClaudeSpendRollover(now: midnight))
        let expectedNovember = try Self.date("2026-11-01T00:00:00Z")
        #expect(atMidnight.resetsAt == expectedNovember)
        #expect(atMidnight.windowMinutes == 31 * 24 * 60)

        let justBefore = try #require(ClaudeSpendRollover(now: beforeMidnight))
        #expect(justBefore.resetsAt == midnight)
        #expect(justBefore.windowMinutes == 30 * 24 * 60)

        let yearEnd = try #require(ClaudeSpendRollover(now: newYearsEve))
        let expectedJanuary = try Self.date("2027-01-01T00:00:00Z")
        #expect(yearEnd.resetsAt == expectedJanuary)
    }

    @Test
    func `every rollover producer marks the reset as inferred`() throws {
        let now = try Self.date("2026-10-07T12:00:00Z")
        let overage = try #require(ClaudeWebAPIFetcher._parseOverageSpendLimitForTesting(Self.overageJSON, now: now))
        #expect(overage.resetsAtIsInferred == true)

        let web = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(
            Data(#"{"five_hour": null, "extra_usage": {"monthly_limit": 20000, "used_credits": 1250}}"#.utf8),
            now: now)
        #expect(web.extraUsageCost?.resetsAtIsInferred == true)

        let monthlyCap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(
            Data(#"""
            {"five_hour": {"utilization": 1, "resets_at": "2026-10-08T00:00:00Z"},
             "extra_usage": {"is_enabled": true, "monthly_limit": 2000, "used_credits": 520}}
            """#.utf8),
            now: now)
        #expect(monthlyCap.providerCost?.period == "Monthly cap")
        #expect(monthlyCap.providerCost?.resetsAtIsInferred == true)

        let spendLimit = try ClaudeUsageFetcher._mapOAuthUsageForTesting(
            Data(#"{"extra_usage": {"is_enabled": true, "monthly_limit": 2000, "used_credits": 520}}"#.utf8),
            subscriptionType: "enterprise",
            now: now)
        #expect(spendLimit.providerCost?.period == "Spend limit")
        #expect(spendLimit.providerCost?.resetsAtIsInferred == true)
    }

    @Test
    func `oauth enterprise payload carries the rollover and drops the primary lane`() throws {
        let json = """
        {
          "five_hour": null,
          "seven_day": null,
          "seven_day_opus": null,
          "seven_day_sonnet": null,
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 20000,
            "used_credits": 1250.0,
            "utilization": 6.25,
            "currency": "USD",
            "decimal_places": 2,
            "disabled_reason": null,
            "user_disabled": false,
            "spend_limit_reached": false,
            "credits_ever_enabled": true,
            "daily": null,
            "weekly": null
          },
          "spend": {
            "used": { "amount_minor": 1250, "currency": "USD", "exponent": 2 },
            "limit": { "amount_minor": 20000, "currency": "USD", "exponent": 2 },
            "percent": 6,
            "severity": "normal",
            "enabled": true
          },
          "limits": [],
          "cedar_ember": {
            "eligible": false,
            "ineligible_reason": "seat",
            "at_limit": false,
            "exhausted": [],
            "grants": []
          }
        }
        """
        let now = try Self.date("2026-10-07T12:00:00Z")
        let snapshot = try ClaudeUsageFetcher._mapOAuthUsageForTesting(
            Data(json.utf8),
            subscriptionType: "enterprise",
            now: now)

        #expect(snapshot.primary == nil)
        let expectedReset = try Self.date("2026-11-01T00:00:00Z")
        let cost = try #require(snapshot.providerCost)
        #expect(cost.period == "Spend limit")
        #expect(cost.limit == 200)
        #expect(cost.used == 12.5)
        #expect(cost.resetsAt == expectedReset)
        #expect(cost.windowMinutes == 31 * 24 * 60)
        let spendWindow = try #require(cost.spendLimitWindow)
        #expect(spendWindow.resetsAt == cost.resetsAt)
        #expect(spendWindow.windowMinutes == cost.windowMinutes)

        let usage = ClaudeOAuthFetchStrategy._snapshotForTesting(from: snapshot)
        #expect(usage.primary == nil)
        #expect(usage.providerCost == cost)
    }
}
