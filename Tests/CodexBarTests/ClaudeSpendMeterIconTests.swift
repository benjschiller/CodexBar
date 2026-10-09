import AppKit
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct ClaudeSpendMeterIconTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static let placeholderSession = RateWindow(
        usedPercent: 0,
        windowMinutes: 300,
        resetsAt: nil,
        resetDescription: nil,
        isSyntheticPlaceholder: true)
    private static let session = RateWindow(usedPercent: 30, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
    private static let weekly = RateWindow(usedPercent: 40, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)

    private static func spendCost(limit: Double = 100) -> ProviderCostSnapshot {
        ProviderCostSnapshot(used: 25, limit: limit, currencyCode: "USD", period: "Spend limit", updatedAt: self.now)
    }

    private static func webSnapshot(_ payload: String) throws -> UsageSnapshot {
        let webData = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(Data(payload.utf8), now: self.now)
        let usage = try ClaudeUsageFetcher.mapWebUsage(webData, includeAccountIdentity: false, now: self.now)
        return ClaudeOAuthFetchStrategy._snapshotForTesting(from: usage)
    }

    private static func oauthSnapshot(_ payload: String) throws -> UsageSnapshot {
        let usage = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(payload.utf8), now: self.now)
        return ClaudeOAuthFetchStrategy._snapshotForTesting(from: usage)
    }

    private func pixels(_ image: NSImage) throws -> Data {
        try #require(image.tiffRepresentation)
    }

    private func icon(
        _ percents: (primary: Double?, secondary: Double?),
        policy: IconRenderer.QuotaLayoutPolicy) -> NSImage
    {
        IconRenderer.makeIcon(
            primaryRemaining: percents.primary,
            weeklyRemaining: percents.secondary,
            creditsRemaining: nil,
            stale: false,
            style: .combined,
            hideCritters: true,
            quotaLayoutPolicy: policy)
    }

    private func claudePercents(
        _ snapshot: UsageSnapshot,
        showUsed: Bool = false) -> (primary: Double?, secondary: Double?)
    {
        IconRemainingResolver.resolvedPercents(
            snapshot: snapshot,
            style: .claude,
            showUsed: showUsed,
            now: Self.now)
    }

    private func claudePolicy(_ snapshot: UsageSnapshot) -> IconRenderer.QuotaLayoutPolicy {
        IconRemainingResolver.quotaLayoutPolicy(provider: .claude, snapshot: snapshot, now: Self.now)
    }

    @Test
    func `spend only claude draws one tall meter`() throws {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: Self.spendCost(),
            updatedAt: Self.now)
        let percents = self.claudePercents(snapshot)
        let policy = self.claudePolicy(snapshot)

        #expect(percents.primary == 75)
        #expect(percents.secondary == nil)
        #expect(policy.reservesMissingSecondaryLane == false)

        let spendOnly = self.icon(percents, policy: policy)
        let singleLane = self.icon(percents, policy: .provider(.codex))
        let reservedLane = self.icon(percents, policy: .provider(.claude))

        #expect(try self.pixels(spendOnly) == self.pixels(singleLane))
        #expect(try self.pixels(spendOnly) != self.pixels(reservedLane))
    }

    @Test
    func `web placeholder never fills the session lane`() throws {
        // Web maps `five_hour: null` like OAuth, so no 0% session window can fill the top lane.
        let weeklyPayload = #"""
        {"five_hour": null, "seven_day": {"utilization": 40, "resets_at": "2026-10-10T00:00:00Z"}}
        """#
        let weeklyOnly = try Self.webSnapshot(weeklyPayload)
        let weeklyPercents = self.claudePercents(weeklyOnly)
        let weeklyPolicy = self.claudePolicy(weeklyOnly)

        #expect(weeklyOnly.primary?.isSyntheticPlaceholder == false)
        #expect(weeklyOnly.primary?.windowMinutes == 7 * 24 * 60)
        #expect(weeklyPercents.primary == 60)
        #expect(weeklyPercents.secondary == 60)
        #expect(weeklyPolicy == .provider(.claude))

        let oauthWeeklyOnly = try Self.oauthSnapshot(weeklyPayload)
        let oauthPercents = self.claudePercents(oauthWeeklyOnly)
        #expect(weeklyPercents.primary == oauthPercents.primary)
        #expect(weeklyPercents.secondary == oauthPercents.secondary)
        let webIcon = self.icon(weeklyPercents, policy: weeklyPolicy)
        let oauthIcon = self.icon(oauthPercents, policy: self.claudePolicy(oauthWeeklyOnly))
        let filledSession = self.icon((primary: 100, secondary: 60), policy: weeklyPolicy)
        #expect(try self.pixels(webIcon) == self.pixels(oauthIcon))
        #expect(try self.pixels(webIcon) != self.pixels(filledSession))

        let spendPayload = #"""
        {"five_hour": null, "seven_day": null,
         "extra_usage": {"monthly_limit": 10000, "used_credits": 2500}}
        """#
        let spendOnly = try Self.webSnapshot(spendPayload)
        #expect(spendOnly.primary == nil)
        #expect(self.claudePercents(spendOnly, showUsed: false).primary == 75)
        #expect(self.claudePercents(spendOnly, showUsed: true).primary == 25)
        #expect(self.claudePolicy(spendOnly).reservesMissingSecondaryLane == false)

        // Snapshots cached by older builds can still carry the placeholder beside a spend cap.
        let cachedSpendOnly = UsageSnapshot(
            primary: Self.placeholderSession,
            secondary: nil,
            providerCost: Self.spendCost(),
            updatedAt: Self.now)
        #expect(self.claudePercents(cachedSpendOnly, showUsed: false).primary == 75)
        #expect(self.claudePercents(cachedSpendOnly, showUsed: true).primary == 25)
    }

    @Test
    func `quota accounts keep session and weekly lanes`() throws {
        let quota = UsageSnapshot(
            primary: Self.session,
            secondary: Self.weekly,
            providerCost: Self.spendCost(),
            updatedAt: Self.now)
        let pair = ClaudeProviderDescriptor.descriptor.presentation.iconWindows(
            context: ProviderIconWindowContext(snapshot: quota, secondaryOverrideWindowID: nil, now: Self.now))

        #expect(pair == ProviderUsageWindowPair(primary: Self.session, secondary: Self.weekly))
        #expect(pair.lanesAreSpendCaps == false)
        #expect(self.claudePolicy(quota) == .provider(.claude))
        let percents = self.claudePercents(quota)
        #expect(percents.primary == 70)
        #expect(percents.secondary == 60)

        let sessionOnly = UsageSnapshot(primary: Self.session, secondary: nil, updatedAt: Self.now)
        let sessionOnlyPolicy = self.claudePolicy(sessionOnly)
        #expect(sessionOnlyPolicy == .provider(.claude))
        let sessionOnlyIcon = self.icon(self.claudePercents(sessionOnly), policy: sessionOnlyPolicy)
        let reservedIcon = self.icon((primary: 70, secondary: nil), policy: .provider(.claude))
        #expect(try self.pixels(sessionOnlyIcon) == self.pixels(reservedIcon))

        let scoped = NamedRateWindow(
            id: "claude-weekly-scoped-example",
            title: "Example only",
            window: Self.weekly,
            usageKnown: true)
        let scopedOnly = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [scoped],
            providerCost: Self.spendCost(),
            updatedAt: Self.now)
        #expect(self.claudePolicy(scopedOnly) == .provider(.claude))
    }

    @Test
    func `spend only without a budget keeps the empty lane`() throws {
        let balanceOnly = ProviderCostSnapshot(
            used: 0,
            limit: 0,
            currencyCode: "USD",
            period: "Extra usage",
            balance: 100,
            updatedAt: Self.now)
        let snapshots = [
            UsageSnapshot(primary: nil, secondary: nil, providerCost: balanceOnly, updatedAt: Self.now),
            UsageSnapshot(primary: nil, secondary: nil, providerCost: Self.spendCost(limit: 0), updatedAt: Self.now),
            UsageSnapshot(primary: nil, secondary: nil, updatedAt: Self.now),
        ]

        for snapshot in snapshots {
            let percents = self.claudePercents(snapshot)
            #expect(percents.primary == nil)
            #expect(percents.secondary == nil)
            #expect(snapshot.claudeSpendOnlyWindow == nil)
            #expect(self.claudePolicy(snapshot) == .provider(.claude))
            #expect(try self.pixels(self.icon(percents, policy: self.claudePolicy(snapshot)))
                == self.pixels(self.icon(percents, policy: .provider(.claude))))
        }
    }

    @Test
    func `claude spend only window needs a budget and no measured lanes`() {
        let spendOnly = UsageSnapshot(primary: nil, secondary: nil, providerCost: Self.spendCost(), updatedAt: Self.now)
        let window = spendOnly.claudeSpendOnlyWindow
        #expect(window?.usedPercent == 25)
        #expect(MenuBarMetricWindowResolver.claudeSpendLimitWindow(snapshot: spendOnly) == window)

        let placeholder = UsageSnapshot(
            primary: Self.placeholderSession,
            secondary: nil,
            providerCost: Self.spendCost(),
            updatedAt: Self.now)
        #expect(placeholder.claudeSpendOnlyWindow == window)

        let measuredLanes = [
            UsageSnapshot(primary: Self.session, secondary: nil, providerCost: Self.spendCost(), updatedAt: Self.now),
            UsageSnapshot(primary: nil, secondary: Self.weekly, providerCost: Self.spendCost(), updatedAt: Self.now),
            UsageSnapshot(
                primary: nil,
                secondary: nil,
                tertiary: Self.weekly,
                providerCost: Self.spendCost(),
                updatedAt: Self.now),
        ]
        for snapshot in measuredLanes {
            #expect(snapshot.claudeSpendOnlyWindow == nil)
            #expect(MenuBarMetricWindowResolver.claudeSpendLimitWindow(snapshot: snapshot) == nil)
        }
    }

    @Test
    func `claude spend only pair flags its lanes as spend caps`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: Self.spendCost(),
            updatedAt: Self.now)
        let pair = ClaudeProviderDescriptor.descriptor.presentation.iconWindows(
            context: ProviderIconWindowContext(snapshot: snapshot, secondaryOverrideWindowID: nil, now: Self.now))

        #expect(pair == ProviderUsageWindowPair(
            primary: snapshot.providerCost?.spendLimitWindow,
            secondary: nil,
            lanesAreSpendCaps: true))
    }

    @Test
    func `other providers keep their layout policy beside a spend budget`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: Self.spendCost(),
            updatedAt: Self.now)
        let pair = CodexProviderDescriptor.descriptor.presentation.iconWindows(
            context: ProviderIconWindowContext(snapshot: snapshot, secondaryOverrideWindowID: nil, now: Self.now))

        #expect(pair.lanesAreSpendCaps == false)
        #expect(IconRemainingResolver.quotaLayoutPolicy(provider: .codex, snapshot: snapshot, now: Self.now)
            == .provider(.codex))
        #expect(IconRemainingResolver.quotaLayoutPolicy(provider: .claude, snapshot: nil, now: Self.now)
            == .provider(.claude))
    }
}
