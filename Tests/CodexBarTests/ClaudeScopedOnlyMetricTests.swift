import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct ClaudeScopedOnlyMetricTests {
    private static let now = Date(timeIntervalSince1970: 1_790_726_400)

    @Test
    func `scoped token ignores windows without measured usage`() {
        let unknown = NamedRateWindow(
            id: "claude-weekly-scoped-example",
            title: "Example only",
            window: RateWindow(usedPercent: 0, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            usageKnown: false)
        let snapshot = UsageSnapshot(primary: nil, secondary: nil, extraRateWindows: [unknown], updatedAt: Self.now)
        #expect(MenuBarLayoutSemanticWindowResolver.scopedWeeklyNamedWindow(snapshot: snapshot) == nil)
    }

    @Test(arguments: [MenuBarMetricPreference.automatic, .primaryAndSecondary], [false, true])
    func `scoped weekly payload supplies the only measured menu bar metric`(
        preference: MenuBarMetricPreference, withSpendLimit: Bool) throws
    {
        let snapshot = try Self.snapshot(withSpendLimit: withSpendLimit)
        let scoped = try #require(MenuBarLayoutSemanticWindowResolver.scopedWeeklyNamedWindow(snapshot: snapshot))
        #expect(scoped.window.usedPercent == 6)
        let selected = MenuBarMetricWindowResolver.rateWindow(
            preference: preference, provider: .claude, snapshot: snapshot, supportsAverage: false, now: Self.now)
        #expect(selected == scoped.window)
        #expect(MenuBarMetricWindowResolver.claudeSpendLimitWindow(snapshot: snapshot) == nil)
    }

    @Test
    func `web scoped payload with a spend cap maps to the spend only shape`() throws {
        let data = Data(#"""
        {"five_hour": null, "seven_day": null,
         "extra_usage": {"monthly_limit": 10000, "used_credits": 2000},
         "limits": [
          {"kind": "weekly_scoped", "group": "weekly", "percent": 6,
           "resets_at": "2026-10-07T09:00:00Z",
           "scope": {"model": {"display_name": "Fable"}}, "is_active": true}
        ]}
        """#.utf8)
        let parsed = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(data)
        let usage = try ClaudeUsageFetcher.mapWebUsage(parsed, includeAccountIdentity: false, now: Self.now)
        let snapshot = ClaudeOAuthFetchStrategy._snapshotForTesting(from: usage)

        #expect(usage.primary == nil)
        #expect(snapshot.primary == nil)
        #expect(snapshot.claudeScopedWeeklyWindow?.window.usedPercent == 6)
        #expect(snapshot.providerCost?.limit == 100)
        #expect(MenuBarMetricWindowResolver.claudeSpendLimitWindow(snapshot: snapshot) == nil)
    }

    @Test(arguments: [MenuBarMetricPreference.automatic, .primaryAndSecondary])
    func `weekly only payload resolves the weekly window for the menu bar metric`(
        preference: MenuBarMetricPreference) throws
    {
        let usage = try ClaudeUsageFetcher._mapOAuthUsageForTesting(
            Data(#"{"five_hour": null, "seven_day": {"utilization": 42}}"#.utf8),
            now: Self.now)
        let snapshot = ClaudeOAuthFetchStrategy._snapshotForTesting(from: usage)

        #expect(snapshot.primary == nil)
        let selected = MenuBarMetricWindowResolver.rateWindow(
            preference: preference, provider: .claude, snapshot: snapshot, supportsAverage: false, now: Self.now)
        #expect(selected?.usedPercent == 42)
        #expect(selected?.windowMinutes == 7 * 24 * 60)
        #expect(MenuBarMetricWindowResolver.claudeSpendLimitWindow(snapshot: snapshot) == nil)
    }

    @Test(arguments: [MenuBarMetricPreference.automatic, .primaryAndSecondary])
    func `OAuth scoped only and spend only payloads keep their menu bar fallbacks`(
        preference: MenuBarMetricPreference) throws
    {
        let scopedUsage = try ClaudeUsageFetcher._mapOAuthUsageForTesting(
            Data(#"""
            {"five_hour": null, "seven_day": null, "limits": [
              {"kind": "weekly_scoped", "group": "weekly", "percent": 6,
               "resets_at": "2026-10-07T09:00:00Z",
               "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": true}
            ]}
            """#.utf8),
            now: Self.now)
        let scoped = ClaudeOAuthFetchStrategy._snapshotForTesting(from: scopedUsage)
        let scopedWindow = try #require(MenuBarLayoutSemanticWindowResolver.scopedWeeklyNamedWindow(snapshot: scoped))
        #expect(scoped.primary == nil)
        let selectedScoped = MenuBarMetricWindowResolver.rateWindow(
            preference: preference, provider: .claude, snapshot: scoped, supportsAverage: false, now: Self.now)
        #expect(selectedScoped == scopedWindow.window)

        let spendUsage = try ClaudeUsageFetcher._mapOAuthUsageForTesting(
            Data(#"""
            {"extra_usage": {"is_enabled": true, "monthly_limit": 10000, "used_credits": 2500, "currency": "USD"}}
            """#.utf8),
            now: Self.now)
        let spend = ClaudeOAuthFetchStrategy._snapshotForTesting(from: spendUsage)
        #expect(spend.primary == nil)
        let selectedSpend = MenuBarMetricWindowResolver.rateWindow(
            preference: preference, provider: .claude, snapshot: spend, supportsAverage: false, now: Self.now)
        #expect(selectedSpend?.usedPercent == 25)
    }

    @MainActor
    @Test
    func `render synthetic scoped only metric proof`() throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_CLAUDE_PRESENTATION_PROOF_DIR"] else {
            return
        }
        let snapshot = try Self.snapshot(withSpendLimit: false)
        let scoped = MenuBarLayoutSemanticWindowResolver.scopedWeeklyNamedWindow(snapshot: snapshot)
        let selected = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic, provider: .claude, snapshot: snapshot, supportsAverage: false, now: Self.now)
        // The red regression established that the previous automatic selector returned the raw placeholder.
        for (stage, window) in [("before", snapshot.primary), ("after", selected)] {
            let data = Self.renderData(snapshot: snapshot, scoped: scoped, automatic: window)
            let layout = MenuBarLayout(lines: [[.providerName, .space, .percent(window: .automatic)]])
            let options = MenuBarLayoutRenderOptions(
                size: .regular,
                highContrast: false,
                showUsed: true,
                conditionals: [],
                appearanceName: NSAppearance.Name.aqua.rawValue,
                isDebugApp: false,
                now: Self.now)
            let title = MenuBarLayoutRenderer().render(layout: layout, data: data, icon: nil, options: options)
            let hosting = NSHostingView(rootView: Text(AttributedString(title.attributedTitle))
                .padding(20)
                .frame(width: 240, height: 70)
                .background(Color(nsColor: .windowBackgroundColor))
                .preferredColorScheme(.light))
            hosting.appearance = NSAppearance(named: .aqua)
            let png = try #require(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("scoped-\(stage).png"))
        }
    }

    @MainActor
    private static func renderData(
        snapshot: UsageSnapshot,
        scoped: NamedRateWindow?,
        automatic: RateWindow?) -> MenuBarLayoutRenderData
    {
        MenuBarLayoutRenderData(
            provider: .claude,
            iconKey: "synthetic-claude-scoped",
            providerName: "Claude",
            accountLabel: nil,
            laneLabels: MenuBarLayoutLaneLabels(provider: .claude, snapshot: snapshot),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            session: nil,
            weekly: nil,
            scopedWeekly: MenuBarLayoutRenderWindow(scoped?.window),
            scopedWeeklyTitle: scoped?.title,
            automatic: MenuBarLayoutRenderWindow(automatic),
            automaticText: nil,
            sessionPace: nil,
            weeklyPace: nil,
            automaticPace: nil,
            runsOut: nil,
            balance: nil,
            costToday: nil,
            cost30d: nil,
            metrics: .unavailable)
    }

    private static func snapshot(withSpendLimit: Bool) throws -> UsageSnapshot {
        let data = Data(#"""
        {"five_hour": null, "seven_day": null, "limits": [
          {"kind": "weekly_scoped", "group": "weekly", "percent": 6,
           "resets_at": "2026-10-07T09:00:00Z",
           "scope": {"model": {"display_name": "Fable"}}, "is_active": true}
        ]}
        """#.utf8)
        let parsed = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(data)
        let cost = ProviderCostSnapshot(
            used: 20,
            limit: 100,
            currencyCode: "USD",
            period: "Monthly",
            updatedAt: Self.now)
        // Web builds `primary` like OAuth, so a payload without session or weekly windows has no primary lane.
        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: parsed.extraRateWindows,
            providerCost: withSpendLimit ? cost : nil,
            updatedAt: Self.now)
    }
}
