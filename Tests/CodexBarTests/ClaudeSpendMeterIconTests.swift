import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

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
        let weeklyOnly = UsageSnapshot(
            primary: Self.placeholderSession,
            secondary: Self.weekly,
            updatedAt: Self.now)
        let weeklyPercents = self.claudePercents(weeklyOnly)
        let weeklyPolicy = self.claudePolicy(weeklyOnly)

        #expect(weeklyPercents.primary == nil)
        #expect(weeklyPercents.secondary == 60)
        #expect(weeklyPolicy == .provider(.claude))
        let honest = self.icon(weeklyPercents, policy: weeklyPolicy)
        let filledSession = self.icon((primary: 100, secondary: 60), policy: weeklyPolicy)
        #expect(try self.pixels(honest) != self.pixels(filledSession))

        let spendOnly = UsageSnapshot(
            primary: Self.placeholderSession,
            secondary: nil,
            providerCost: Self.spendCost(),
            updatedAt: Self.now)
        #expect(self.claudePercents(spendOnly, showUsed: false).primary == 75)
        #expect(self.claudePercents(spendOnly, showUsed: true).primary == 25)
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
            UsageSnapshot(primary: Self.placeholderSession, secondary: nil, updatedAt: Self.now),
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
