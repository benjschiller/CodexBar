import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MenuBarSpendLimitTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore(showOptionalCreditsAndExtraUsage: Bool = true) -> UsageStore {
        let settings = testSettingsStore(suiteName: "MenuBarSpendLimitTests", userDefaults: InMemoryUserDefaults())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.showOptionalCreditsAndExtraUsage = showOptionalCreditsAndExtraUsage
        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
    }

    private func monthlyBudget(
        used: Double = 460,
        limit: Double = 1000,
        currencyCode: String = "USD",
        balance: Double? = nil,
        resetsIn days: Double = 12) -> ProviderCostSnapshot
    {
        ProviderCostSnapshot(
            used: used,
            limit: limit,
            currencyCode: currencyCode,
            period: "Monthly",
            resetsAt: self.now.addingTimeInterval(days * 24 * 60 * 60),
            balance: balance,
            windowMinutes: 30 * 24 * 60,
            updatedAt: self.now)
    }

    private func snapshot(_ cost: ProviderCostSnapshot?) -> UsageSnapshot {
        UsageSnapshot(primary: nil, secondary: nil, providerCost: cost, updatedAt: self.now)
    }

    @Test(arguments: [UsageProvider.claude, .cursor])
    func `a provider reported budget resolves through the seam`(provider: UsageProvider) throws {
        let store = self.makeStore()
        defer { store.stopSharedSpendDashboardPublication() }
        let budget = self.monthlyBudget()

        let limit = try #require(store.spendLimit(for: provider, snapshot: self.snapshot(budget), now: self.now))

        #expect(limit.used == 460)
        #expect(limit.limit == 1000)
        #expect(limit.currencyCode == "USD")
        #expect(limit.isMonetary)
        #expect(limit.window.usedPercent == 46)
        #expect(limit.window.windowMinutes == 30 * 24 * 60)
        #expect(limit.window.resetsAt == budget.resetsAt)
    }

    @Test
    func `the show credits and extra usage switch hides the budget`() {
        let store = self.makeStore(showOptionalCreditsAndExtraUsage: false)
        defer { store.stopSharedSpendDashboardPublication() }

        let snapshot = self.snapshot(self.monthlyBudget())

        #expect(store.spendLimit(for: .claude, snapshot: snapshot, now: self.now) == nil)
        #expect(!store.supportsSpendLimit(for: .claude))
        #expect(store.menuBarLayoutSpend(provider: .claude, snapshot: snapshot, now: self.now) == .unavailable)
    }

    @Test
    func `a snapshot without a positive budget has no spend limit`() {
        let store = self.makeStore()
        defer { store.stopSharedSpendDashboardPublication() }

        #expect(store.spendLimit(for: .claude, snapshot: nil, now: self.now) == nil)
        #expect(store.spendLimit(for: .claude, snapshot: self.snapshot(nil), now: self.now) == nil)
        #expect(store.spendLimit(
            for: .claude,
            snapshot: self.snapshot(self.monthlyBudget(limit: 0)),
            now: self.now) == nil)
    }

    @Test(arguments: [UsageProvider.opencodego, .deepseek, .openrouter, .gemini])
    func `providers without the extra usage capability never expose provider cost as a budget`(
        provider: UsageProvider)
    {
        let store = self.makeStore()
        defer { store.stopSharedSpendDashboardPublication() }
        // A Zen-style balance carries a positive limit; it must still never become a budget.
        let balance = ProviderCostSnapshot(
            used: 12,
            limit: 100,
            currencyCode: "USD",
            period: "Zen balance",
            updatedAt: self.now)

        #expect(!store.supportsSpendLimit(for: provider))
        #expect(store.spendLimit(for: provider, snapshot: self.snapshot(balance), now: self.now) == nil)
    }

    @Test
    func `Codex credit caps resolve through the consumer projection as non monetary`() throws {
        let store = self.makeStore()
        defer { store.stopSharedSpendDashboardPublication() }
        let cap = ProviderCostSnapshot(
            used: 200,
            limit: 1000,
            currencyCode: CodexExtraUsageCost.currencyCode,
            period: "Monthly credit limit",
            resetsAt: self.now.addingTimeInterval(10 * 24 * 60 * 60),
            updatedAt: self.now)
        store._setSnapshotForTesting(self.snapshot(cap), provider: .codex)

        let limit = try #require(store.spendLimit(for: .codex, snapshot: self.snapshot(cap), now: self.now))

        #expect(!limit.isMonetary)
        #expect(limit.window.usedPercent == 20)
        #expect(limit.currencySymbol.isEmpty)
        #expect(limit.amountText(preferredCurrency: "USD") == nil)
        #expect(limit.budgetText(preferredCurrency: "USD") == nil)
    }

    @Test
    func `a Codex credit balance without a cap never becomes a budget`() {
        let store = self.makeStore()
        defer { store.stopSharedSpendDashboardPublication() }
        let balanceOnly = ProviderCostSnapshot(
            used: 0,
            limit: 0,
            currencyCode: CodexExtraUsageCost.currencyCode,
            balance: 42,
            balanceUpdatedAt: self.now,
            updatedAt: self.now)

        #expect(store.spendLimit(for: .codex, snapshot: self.snapshot(balanceOnly), now: self.now) == nil)
    }

    @Test
    func `Codex credit caps honor the show credits and extra usage switch`() {
        let store = self.makeStore(showOptionalCreditsAndExtraUsage: false)
        defer { store.stopSharedSpendDashboardPublication() }
        let cap = ProviderCostSnapshot(
            used: 200,
            limit: 1000,
            currencyCode: CodexExtraUsageCost.currencyCode,
            updatedAt: self.now)

        #expect(store.spendLimit(for: .codex, snapshot: self.snapshot(cap), now: self.now) == nil)
    }

    @Test
    func `money text follows the display currency and the budget symbol prefixes the percent`() throws {
        let sterling = MenuBarSpendLimit(
            window: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            used: 100,
            limit: 200,
            currencyCode: "GBP",
            isMonetary: true)

        #expect(sterling.currencySymbol == "£")
        #expect(sterling.amountText(preferredCurrency: "auto") == "£100")
        #expect(sterling.budgetText(preferredCurrency: "auto") == "£100 / £200")

        let toUSD = try #require(CurrencyExchange.shared.convert(amount: 100, from: "GBP", to: "USD"))
        let limitInUSD = try #require(CurrencyExchange.shared.convert(amount: 200, from: "GBP", to: "USD"))
        let expectedUsed = UsageFormatter.compactCurrencyString(toUSD, currencyCode: "USD")
        let expectedLimit = UsageFormatter.compactCurrencyString(limitInUSD, currencyCode: "USD")
        #expect(sterling.amountText(preferredCurrency: "USD") == expectedUsed)
        #expect(sterling.budgetText(preferredCurrency: "USD") == "\(expectedUsed) / \(expectedLimit)")
        // The prefix names the budget's own currency whichever currency the amounts display in.
        #expect(sterling.currencySymbol == "£")
    }

    @Test
    func `layout spend resolves window text and pace together`() {
        let store = self.makeStore()
        defer { store.stopSharedSpendDashboardPublication() }
        let snapshot = self.snapshot(self.monthlyBudget())

        let spend = store.menuBarLayoutSpend(provider: .claude, snapshot: snapshot, now: self.now)

        #expect(spend.window?.usedPercent == 46)
        #expect(spend.amount == "$460")
        #expect(spend.budget == "$460 / $1,000")
        #expect(spend.currencySymbol == "$")
        // 12 of 30 days remain, so 60% of the period has elapsed against 46% spent.
        #expect(spend.paceDelta == -14)
        #expect(spend.pace == "-14%")
    }

    @Test
    func `layout spend pace follows the pace sign preference without flipping the delta`() {
        let store = self.makeStore()
        defer { store.stopSharedSpendDashboardPublication() }
        store.settings.menuBarPaceReservePositive = true

        let spend = store.menuBarLayoutSpend(
            provider: .claude,
            snapshot: self.snapshot(self.monthlyBudget()),
            now: self.now)

        #expect(spend.pace == "+14%")
        #expect(spend.paceDelta == -14)
    }

    @Test
    func `a Claude prepaid balance never becomes a spend budget or amount`() {
        let store = self.makeStore()
        defer { store.stopSharedSpendDashboardPublication() }
        let balanceOnly = ProviderCostSnapshot(
            used: 0,
            limit: 0,
            currencyCode: "USD",
            period: "Prepaid",
            balance: 25,
            updatedAt: self.now)
        let budgetWithBalance = self.monthlyBudget(balance: 25)

        #expect(store.spendLimit(for: .claude, snapshot: self.snapshot(balanceOnly), now: self.now) == nil)
        #expect(store.menuBarLayoutSpend(
            provider: .claude,
            snapshot: self.snapshot(balanceOnly),
            now: self.now) == .unavailable)

        let spend = store.menuBarLayoutSpend(
            provider: .claude,
            snapshot: self.snapshot(budgetWithBalance),
            now: self.now)
        #expect(spend.amount == "$460")
        #expect(spend.budget == "$460 / $1,000")
        #expect(spend.remainingUSD == 540)
    }

    @Test(arguments: [UsageProvider.claude, .codex, .cursor])
    func `spend pace is a plain linear read for every provider`(provider: UsageProvider) {
        let store = self.makeStore()
        defer { store.stopSharedSpendDashboardPublication() }
        let window = RateWindow(
            usedPercent: 46,
            windowMinutes: 30 * 24 * 60,
            resetsAt: self.now.addingTimeInterval(12 * 24 * 60 * 60),
            resetDescription: nil)

        let pace = store.spendPace(provider: provider, window: window, dataConfidence: .unknown, now: self.now)

        #expect(pace?.deltaPercent.rounded() == -14)
    }

    @Test
    func `spend pace waits for a window length and the weekly eligibility floors`() {
        let store = self.makeStore()
        defer { store.stopSharedSpendDashboardPublication() }
        let month = 30.0 * 24 * 60 * 60
        let make = { (usedPercent: Double, windowMinutes: Int?, elapsed: TimeInterval) in
            RateWindow(
                usedPercent: usedPercent,
                windowMinutes: windowMinutes,
                resetsAt: self.now.addingTimeInterval(month - elapsed),
                resetDescription: nil)
        }
        let pace = { (window: RateWindow) in
            store.spendPace(provider: .claude, window: window, dataConfidence: .unknown, now: self.now)
        }

        // A window without a duration cannot be paced, and a spent budget has no pace left to report.
        #expect(pace(make(10, nil, month / 2)) == nil)
        #expect(pace(make(100, 30 * 24 * 60, month / 2)) == nil)
        // Under 1% elapsed and under 3% expected: too early to read.
        #expect(pace(make(0, 30 * 24 * 60, month * 0.005)) == nil)
        // One percent of the period elapsed is enough even while expected use stays under 3%.
        #expect(pace(make(0, 30 * 24 * 60, month * 0.011)) != nil)
    }
}
