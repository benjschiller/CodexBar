import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct MenuBarSpendCountdownRefreshTests {
    /// The spend reset predicate gets the same exact wake-up as the quota windows.
    @Test
    func `predicate-only spend reset countdown conditional schedules its flip instant`() {
        let controller = Self.makeController(
            suite: "MenuBarSpendCountdownRefreshTests-predicate-only-spend-reset",
            resetsInHours: 3)
        defer { controller.releaseStatusItemsForTesting() }
        #expect(controller._test_isMenuBarCountdownRefreshScheduled())
    }

    /// Without a period boundary there is no instant to flip at, so nothing may be scheduled.
    @Test
    func `spend reset predicate without a reset date schedules nothing`() {
        let controller = Self.makeController(
            suite: "MenuBarSpendCountdownRefreshTests-predicate-only-spend-no-reset",
            resetsInHours: nil)
        defer { controller.releaseStatusItemsForTesting() }
        #expect(!controller._test_isMenuBarCountdownRefreshScheduled())
    }

    /// Spend pace is clock-derived like the quota paces, so a predicate on it needs the minute tick.
    @Test
    func `predicate-only spend pace conditional schedules a refresh`() {
        let controller = Self.makeController(
            suite: "MenuBarSpendCountdownRefreshTests-predicate-only-spend-pace",
            metric: .spendPace,
            resetsInHours: nil)
        defer { controller.releaseStatusItemsForTesting() }
        #expect(controller._test_isMenuBarCountdownRefreshScheduled())
    }

    @Test
    func `spend reset tokens contribute their window to the countdown dates`() {
        let settings = testSettingsStore(suiteName: "MenuBarSpendCountdownRefreshTests-token-dates")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.menuBarShowsBrandIconWithPercent = true
        settings.menuBarLayout = MenuBarLayout(lines: [[
            .windowResetCountdown(window: .spend), .windowResetAbsolute(window: .spend),
        ]])
        let controller = Self.makeController(settings: settings, resetsInHours: 3)
        defer { controller.releaseStatusItemsForTesting() }
        let now = Date()
        let reset = now.addingTimeInterval(3 * 60 * 60)
        let snapshot = controller.store.menuBarSnapshot(for: UsageProvider.claude.instanceID)

        #expect(snapshot?.providerCost?.resetsAt != nil)
        let countdown = controller.menuBarLayoutResetDates(for: .claude, now: now, absolute: false)
        let absolute = controller.menuBarLayoutResetDates(for: .claude, now: now, absolute: true)
        #expect(countdown.count == 1)
        #expect(absolute.count == 1)
        #expect(countdown.first.map { abs($0.timeIntervalSince(reset)) < 5 } == true)
        #expect(absolute == countdown)
    }

    private static func makeController(
        suite: String,
        metric: MenuBarConditionalMetric = .spendResetsIn,
        resetsInHours: Double?)
        -> StatusItemController
    {
        let settings = testSettingsStore(suiteName: suite)
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.menuBarShowsBrandIconWithPercent = true
        let conditional = MenuBarLayoutConditional(
            name: "gate",
            clauses: [MenuBarConditionalClause(
                combinator: nil,
                predicate: MenuBarConditionalPredicate(metric: metric, comparison: .lessThan, threshold: 1))],
            thenToken: .providerName,
            elseToken: .hidden)
        settings.menuBarLayoutConditionals = [conditional]
        settings.menuBarLayout = MenuBarLayout(lines: [[.icon, .conditional(id: conditional.id)]])
        return self.makeController(settings: settings, resetsInHours: resetsInHours)
    }

    private static func makeController(settings: SettingsStore, resetsInHours: Double?) -> StatusItemController {
        if let metadata = ProviderRegistry.shared.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: true)
        }
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())

        let now = Date()
        let budget = ProviderCostSnapshot(
            used: 420,
            limit: 1000,
            currencyCode: "USD",
            period: "Monthly",
            resetsAt: resetsInHours.map { now.addingTimeInterval($0 * 60 * 60) },
            windowMinutes: resetsInHours == nil ? nil : 30 * 24 * 60,
            updatedAt: now)
        store._setSnapshotForTesting(
            UsageSnapshot(primary: nil, secondary: nil, providerCost: budget, updatedAt: now),
            provider: .claude)
        controller.updateIcons()
        return controller
    }
}
