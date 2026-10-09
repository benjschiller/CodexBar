import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

/// Spend tokens read a budget that no other signature component covers, so each case moves exactly one
/// budget input while the quota fields stay fixed.
@MainActor
@Suite(.serialized)
struct StatusItemSpendSignatureTests {
    @Test
    func `spend percent changes the observation signature`() {
        let harness = Self.makeHarness(lines: [[.icon, .percent(window: .spend)]])
        defer { harness.controller.releaseStatusItemsForTesting() }

        let first = harness.signature(used: 420)
        let second = harness.signature(used: 450)

        #expect(first.contains("layoutSpend=used="))
        #expect(first != second)
    }

    @Test
    func `spend reset token follows a moved period boundary`() {
        let harness = Self.makeHarness(lines: [[.windowResetCountdown(window: .spend)]])
        defer { harness.controller.releaseStatusItemsForTesting() }

        // Same budget, different boundary: only the spend component can tell the two apart.
        let early = harness.signature(used: 420, resetsInDays: 12)
        let late = harness.signature(used: 420, resetsInDays: 20)

        #expect(early.contains("resetsAt="))
        #expect(early != late)
    }

    @Test
    func `spend signature is exact so a sub cent change redraws a percent token`() {
        let harness = Self.makeHarness(lines: [[.percent(window: .spend)]])
        defer { harness.controller.releaseStatusItemsForTesting() }

        // Both amounts display as "$420" and the same three-decimal percent, so only the exact used share differs.
        let below = harness.signature(used: 420.00, limit: 100_000)
        let above = harness.signature(used: 420.01, limit: 100_000)

        #expect(below != above)
    }

    @Test
    func `spend money tokens sign the formatted amount and budget`() {
        let harness = Self.makeHarness(lines: [[.spendBudget]])
        defer { harness.controller.releaseStatusItemsForTesting() }

        let first = harness.signature(used: 420, limit: 1000)
        let second = harness.signature(used: 420, limit: 1250)

        #expect(first.contains("budget=$420 / $1,000"))
        #expect(first != second)
    }

    @Test
    func `layouts without spend tokens do not sign the budget`() {
        let harness = Self.makeHarness(lines: [[.icon, .percent(window: .session)]])
        defer { harness.controller.releaseStatusItemsForTesting() }

        #expect(harness.signature(used: 420).contains("layoutSpend=nil"))
    }

    @Test
    func `spend pace token signs its own pace`() {
        let harness = Self.makeHarness(lines: [[.pace(window: .spend)]])
        defer { harness.controller.releaseStatusItemsForTesting() }

        let behind = harness.signature(used: 200)
        let ahead = harness.signature(used: 800)

        #expect(behind.contains("layoutPace=spend="))
        #expect(behind != ahead)
    }

    @Test
    func `spend percent predicate moves the signature with the budget`() {
        let harness = Self.makeHarness(metric: .spend, comparison: .greaterThan, threshold: 50)
        defer { harness.controller.releaseStatusItemsForTesting() }

        let below = harness.signature(used: 420)
        let above = harness.signature(used: 550)

        #expect(below.contains("layoutCondWindows=spend="))
        #expect(below.contains("layoutSpend=used="))
        #expect(below != above)
    }

    @Test
    func `spend reset predicate follows a moved period boundary`() {
        let harness = Self.makeHarness(metric: .spendResetsIn, comparison: .lessThan, threshold: 48)
        defer { harness.controller.releaseStatusItemsForTesting() }

        let early = harness.signature(used: 420, resetsInDays: 1)
        let late = harness.signature(used: 420, resetsInDays: 20)

        #expect(early.contains("layoutCondWindows=spendResetsIn="))
        #expect(early != late)
    }

    @Test
    func `spend pace predicate signs the spend pace`() {
        let harness = Self.makeHarness(metric: .spendPace, comparison: .greaterThan, threshold: 5)
        defer { harness.controller.releaseStatusItemsForTesting() }

        let behind = harness.signature(used: 200)
        let ahead = harness.signature(used: 800)

        #expect(behind.contains("layoutPace=spend="))
        #expect(behind != ahead)
    }

    @Test
    func `spend amount predicate signs the unrounded USD figures`() {
        let harness = Self.makeHarness(metric: .spendAmount, comparison: .greaterThan, threshold: 420.005)
        defer { harness.controller.releaseStatusItemsForTesting() }

        // Both amounts display as "$420", so only the exact USD figure can tell them apart.
        let below = harness.signature(used: 420.00, limit: 100_000)
        let above = harness.signature(used: 420.01, limit: 100_000)

        #expect(below.contains("usedUSD="))
        #expect(!below.contains("usedUSD=unused"))
        #expect(below != above)
    }

    @Test
    func `a percent predicate leaves the USD figures unsigned`() {
        let harness = Self.makeHarness(metric: .spend, comparison: .greaterThan, threshold: 50)
        defer { harness.controller.releaseStatusItemsForTesting() }

        #expect(harness.signature(used: 420).contains("usedUSD=unused"))
    }

    @MainActor
    private struct Harness {
        let store: UsageStore
        let controller: StatusItemController
        let now: Date

        func signature(
            used: Double,
            limit: Double = 1000,
            resetsInDays: Double = 12)
            -> String
        {
            let budget = ProviderCostSnapshot(
                used: used,
                limit: limit,
                currencyCode: "USD",
                period: "Monthly",
                resetsAt: self.now.addingTimeInterval(resetsInDays * 24 * 60 * 60),
                windowMinutes: 30 * 24 * 60,
                updatedAt: self.now)
            self.store._setSnapshotForTesting(
                UsageSnapshot(primary: nil, secondary: nil, providerCost: budget, updatedAt: self.now),
                provider: .claude)
            return self.controller.storeIconObservationSignature()
        }
    }

    /// A layout whose only link to the budget is a conditional predicate: no spend token is placed.
    private static func makeHarness(
        metric: MenuBarConditionalMetric,
        comparison: MenuBarConditionalComparison,
        threshold: Double)
        -> Harness
    {
        let conditional = MenuBarLayoutConditional(
            name: "gate",
            clauses: [MenuBarConditionalClause(
                combinator: nil,
                predicate: MenuBarConditionalPredicate(metric: metric, comparison: comparison, threshold: threshold))],
            thenToken: .providerName,
            elseToken: .hidden)
        return self.makeHarness(
            lines: [[.icon, .conditional(id: conditional.id)]],
            conditionals: [conditional])
    }

    private static func makeHarness(
        lines: [[MenuBarLayoutToken]],
        conditionals: [MenuBarLayoutConditional] = [])
        -> Harness
    {
        let settings = testSettingsStore(suiteName: "StatusItemSpendSignatureTests")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.menuBarShowsBrandIconWithPercent = true
        settings.menuBarLayoutConditionals = conditionals
        settings.menuBarLayout = MenuBarLayout(lines: lines)
        if let claudeMeta = ProviderRegistry.shared.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        return Harness(store: store, controller: controller, now: Date())
    }
}
