import CodexBarCore
import Foundation

/// A provider-reported spend budget behind the menu bar layout's Spend window.
struct MenuBarSpendLimit: Equatable {
    let window: RateWindow
    let used: Double
    let limit: Double
    let currencyCode: String
    /// False for credit-denominated caps, whose amounts have no currency to format or compare against USD.
    let isMonetary: Bool
}

extension MenuBarSpendLimit {
    /// The budget currency's own symbol: the Spend percent's prefix, whatever currency the amounts display in.
    /// Credit-denominated caps have no symbol, so their percent renders unprefixed like the automatic one.
    var currencySymbol: String {
        guard self.isMonetary else { return "" }
        if self.currencyCode == "USD" { return "$" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = self.currencyCode
        formatter.locale = Locale(identifier: "en_US")
        return formatter.currencySymbol.flatMap { $0.isEmpty ? nil : $0 } ?? "$"
    }

    func amountText(preferredCurrency: String) -> String? {
        guard self.isMonetary else { return nil }
        return self.displayText(self.used, preferredCurrency: preferredCurrency)
    }

    func budgetText(preferredCurrency: String) -> String? {
        guard self.isMonetary else { return nil }
        let used = self.displayText(self.used, preferredCurrency: preferredCurrency)
        return "\(used) / \(self.displayText(self.limit, preferredCurrency: preferredCurrency))"
    }

    /// Thresholds are USD. `convertedCost` hands back the source amount unchanged when no rate exists, so
    /// the datum is kept only when the conversion actually landed in USD.
    var usedUSD: Double? {
        self.usdAmount(self.used)
    }

    var remainingUSD: Double? {
        self.usdAmount(max(0, self.limit - self.used))
    }

    private func usdAmount(_ value: Double) -> Double? {
        guard self.isMonetary else { return nil }
        let converted = UsageFormatter.convertedCost(
            value,
            preferredCurrency: "USD",
            providerCurrency: self.currencyCode)
        return converted.currencyCode == "USD" ? converted.value : nil
    }

    private func displayText(_ value: Double, preferredCurrency: String) -> String {
        let converted = UsageFormatter.convertedCost(
            value,
            preferredCurrency: preferredCurrency,
            providerCurrency: self.currencyCode)
        return UsageFormatter.compactCurrencyString(converted.value, currencyCode: converted.currencyCode)
    }
}

/// Menu-bar-ready Spend values resolved in one pass, shared by the status item and the editor preview.
struct MenuBarLayoutSpend: Equatable {
    var window: RateWindow?
    /// Signed pace delta, already formatted (`+11%`, `-8%`, `0%`).
    var pace: String?
    /// The same delta in whole percentage points, which conditional predicates compare.
    var paceDelta: Double?
    var amount: String?
    var budget: String?
    var currencySymbol: String
    var usedUSD: Double?
    var remainingUSD: Double?

    static let unavailable = MenuBarLayoutSpend(
        window: nil,
        pace: nil,
        paceDelta: nil,
        amount: nil,
        budget: nil,
        currencySymbol: "$",
        usedUSD: nil,
        remainingUSD: nil)
}

extension UsageStore {
    /// Whether the provider can report a spend budget at all, before any snapshot arrives. Balances and
    /// credit pools never qualify: only providers that declare `.extraUsage` expose a budget to read.
    func supportsSpendLimit(for provider: UsageProvider) -> Bool {
        self.settings.showOptionalCreditsAndExtraUsage
            && ProviderDescriptorRegistry.descriptor(for: provider).menuBarMetrics.supports(.extraUsage)
    }

    /// The provider's spend budget, resolved the way the `.extraUsage` menu bar metric resolves it.
    func spendLimit(
        for provider: UsageProvider,
        snapshot: UsageSnapshot?,
        now: Date = .init())
        -> MenuBarSpendLimit?
    {
        guard self.supportsSpendLimit(for: provider) else { return nil }
        // Codex keeps its spend behind the consumer projection; every other provider reports it on the snapshot.
        let cost = if let projection = self.codexConsumerProjectionIfNeeded(
            for: provider,
            surface: .menuBar,
            snapshotOverride: snapshot,
            now: now)
        {
            projection.extraUsageCost
        } else {
            snapshot?.providerCost
        }
        guard let cost, cost.used >= 0, let window = cost.spendLimitWindow else { return nil }
        return MenuBarSpendLimit(
            window: window,
            used: cost.used,
            limit: cost.limit,
            currencyCode: cost.currencyCode,
            isMonetary: cost.isMonetary)
    }

    func menuBarLayoutSpend(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        now: Date = .init())
        -> MenuBarLayoutSpend
    {
        guard let limit = self.spendLimit(for: provider, snapshot: snapshot, now: now) else { return .unavailable }
        let preferredCurrency = self.settings.preferredCurrencyCode
        let pace = self.spendPace(
            provider: provider,
            window: limit.window,
            dataConfidence: snapshot?.dataConfidence ?? .unknown,
            now: now)
        return MenuBarLayoutSpend(
            window: limit.window,
            pace: MenuBarDisplayText.paceText(
                pace: pace,
                reservePositive: self.settings.menuBarPaceReservePositive),
            paceDelta: pace.map { $0.deltaPercent.rounded() },
            amount: limit.amountText(preferredCurrency: preferredCurrency),
            budget: limit.budgetText(preferredCurrency: preferredCurrency),
            currencySymbol: limit.currencySymbol,
            usedUSD: limit.usedUSD,
            remainingUSD: limit.remainingUSD)
    }

    /// A plain linear read of the budget period with the weekly pace's eligibility floors. It never goes
    /// through `weeklyPace`, whose Codex branch would score a spend window against learned weekly history.
    func spendPace(
        provider: UsageProvider,
        window: RateWindow,
        dataConfidence: UsageDataConfidence,
        now: Date)
        -> UsagePace?
    {
        guard ProviderDescriptorRegistry.descriptor(for: provider).pace.allowsPace(dataConfidence: dataConfidence),
              window.remainingPercent > 0,
              window.windowMinutes != nil,
              let pace = UsagePace.weekly(window: window, now: now, defaultWindowMinutes: 10080, workDays: nil)
        else { return nil }
        let elapsedFloorMet = Self.paceElapsedBoundary(window: window, minimumElapsedPercent: 1)
            .map { $0 <= now } ?? false
        return pace.expectedUsedPercent >= 3 || elapsedFloorMet ? pace : nil
    }
}
