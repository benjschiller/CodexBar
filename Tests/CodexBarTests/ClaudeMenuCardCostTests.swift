import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ClaudeMenuCardCostTests {
    private static let now = Date(timeIntervalSince1970: 1_782_000_000)
    /// The next 00:00 UTC on the 1st after `now`, ten days into a thirty-day month.
    private static let monthRollover = Date(timeIntervalSince1970: 1_782_864_000)
    private static let juneMinutes = 30 * 24 * 60

    @Test(arguments: [
        (used: 0.0, percent: 0.0, spend: "$0.00"),
        (used: 25.0, percent: 25.0, spend: "$25.00"),
        (used: 100.0, percent: 100.0, spend: "$100.00"),
        (used: 125.0, percent: 100.0, spend: "$125.00"),
    ], [false, true])
    func `claude capped extra usage fill follows the preference without changing spend`(
        sample: (used: Double, percent: Double, spend: String),
        showUsed: Bool) throws
    {
        let model = try Self.makeModel(cost: Self.cost(used: sample.used, limit: 100), showUsed: showUsed)
        let section = try #require(model.providerCost)

        #expect(section.percentUsed == sample.percent)
        #expect(section.displayPercent == (showUsed ? sample.percent : 100 - sample.percent))
        #expect(section.percentStyle == (showUsed ? .used : .left))
        #expect(section.progressAccessibilityLabel == (showUsed ? "Extra usage spent" : "Usage remaining"))
        #expect(section.spendLine == "Monthly cap: \(sample.spend) / $100.00")
        #expect(section.percentLine == "\(Int(sample.percent))% used")
    }

    @Test(arguments: [false, true])
    func `claude extra usage card shows balance above monthly cap`(showUsed: Bool) throws {
        let model = try Self.makeModel(cost: Self.cost(used: 5, limit: 20, balance: 100), showUsed: showUsed)
        let section = try #require(model.providerCost)

        #expect(section.title == "Extra usage")
        #expect(section.balanceLine == "Balance: $100.00")
        #expect(section.spendLine == "Monthly cap: $5.00 / $20.00")
        #expect(section.percentUsed == 25)
        #expect(section.displayPercent == (showUsed ? 25 : 75))
        #expect(section.percentLine == "25% used")
        #expect(section.presentation == .detail)
        #expect(section.showsInProviderDetails == false)
    }

    @Test(arguments: [0.0, -1.0], [false, true])
    func `claude balance only card stays compact`(limit: Double, showUsed: Bool) throws {
        let model = try Self.makeModel(cost: Self.cost(used: 0, limit: limit, balance: 100), showUsed: showUsed)
        let section = try #require(model.providerCost)

        #expect(section.title == "Credits")
        #expect(section.spendLine == "$100.00")
        #expect(section.balanceLine == nil)
        #expect(section.percentUsed == nil)
        #expect(section.displayPercent == nil)
        #expect(section.percentLine == nil)
        #expect(section.presentation == .inlineValue)
        #expect(section.showsInProviderDetails == false)
    }

    @Test(arguments: [0.0, -1.0], [false, true])
    func `claude extra usage without a positive cap or balance stays absent`(limit: Double, showUsed: Bool) throws {
        let model = try Self.makeModel(cost: Self.cost(used: 25, limit: limit), showUsed: showUsed)
        #expect(model.providerCost == nil)
    }

    @Test(arguments: [false, true])
    func `claude missing cost stays absent`(showUsed: Bool) throws {
        let model = try Self.makeModel(cost: nil, showUsed: showUsed)
        #expect(model.providerCost == nil)
    }

    @Test(arguments: [0.0, 100.0], [false, true])
    func `claude optional extra usage and balances stay hidden`(limit: Double, showUsed: Bool) throws {
        let model = try Self.makeModel(
            cost: Self.cost(used: 25, limit: limit, balance: 100),
            showUsed: showUsed,
            showOptional: false)
        #expect(model.providerCost == nil)
    }

    @Test(arguments: [false, true], [false, true])
    func `claude admin api spend remains visible without prepaid balance`(
        showUsed: Bool,
        showOptional: Bool) throws
    {
        let model = try Self.makeModel(
            cost: Self.cost(used: 12.34, limit: 0, period: "Last 30 days"),
            showUsed: showUsed,
            showOptional: showOptional,
            isAdminAPI: true)
        let section = try #require(model.providerCost)

        #expect(section.title == "API spend")
        #expect(section.spendLine == "Last 30 days: $12.34")
        #expect(section.percentUsed == nil)
        #expect(section.displayPercent == nil)
        #expect(section.percentLine == nil)
        #expect(section.presentation == .detail)
        #expect(section.showsInProviderDetails == true)
    }

    @Test(arguments: [false, true])
    func `claude admin api spend still follows summary visibility`(showUsed: Bool) throws {
        let model = try Self.makeModel(
            cost: Self.cost(used: 12.34, limit: 0, period: "Last 30 days"),
            showUsed: showUsed,
            isAdminAPI: true,
            costSummaryInlineEnabled: false)
        #expect(model.providerCost == nil)
    }

    @Test(arguments: [false, true])
    func `claude monthly cap stays visible when prepaid balance is unavailable`(showUsed: Bool) throws {
        let model = try Self.makeModel(cost: Self.cost(used: 0.49, limit: 50), showUsed: showUsed)
        let section = try #require(model.providerCost)

        #expect(section.title == "Extra usage")
        #expect(section.balanceLine == nil)
        #expect(section.spendLine == "Monthly cap: $0.49 / $50.00")
        let percentUsed = try #require(section.percentUsed)
        let displayPercent = try #require(section.displayPercent)
        #expect(abs(percentUsed - 0.98) < 0.0001)
        #expect(abs(displayPercent - (showUsed ? 0.98 : 99.02)) < 0.0001)
        #expect(section.percentLine == "1% used")
        #expect(section.presentation == .detail)
        #expect(section.showsInProviderDetails == false)
    }

    @Test(arguments: [false, true])
    func `claude spend cap shows rollover and pace`(showUsed: Bool) throws {
        let reserveModel = try Self.makeModel(cost: Self.cadencedCost(used: 40), showUsed: showUsed)
        let reserve = try #require(reserveModel.providerCost)

        #expect(reserve.spendLine == "Monthly cap: $40.00 / $100.00")
        #expect(reserve.resetText == "Resets in 10d")
        #expect(reserve.paceText == "Lasts until reset")
        #expect(reserve.paceOnTop)
        let reservePace = try #require(reserve.pacePercent)
        #expect(abs(reservePace - (showUsed ? 200.0 / 3 : 100.0 / 3)) < 0.0001)

        let deficitModel = try Self.makeModel(cost: Self.cadencedCost(used: 90), showUsed: showUsed)
        let deficit = try #require(deficitModel.providerCost)

        #expect(deficit.resetText == "Resets in 10d")
        #expect(deficit.paceText == "Runs out in 2d 5h")
        #expect(deficit.paceOnTop == false)
        let deficitPace = try #require(deficit.pacePercent)
        #expect(abs(deficitPace - (showUsed ? 200.0 / 3 : 100.0 / 3)) < 0.0001)
    }

    @Test(arguments: [40.0, 67.0, 90.0])
    func `claude spend cap pace text omits the deficit and reserve wording`(used: Double) throws {
        let model = try Self.makeModel(cost: Self.cadencedCost(used: used), showUsed: true)
        let section = try #require(model.providerCost)
        let paceText = try #require(section.paceText)

        #expect(paceText.hasPrefix("Runs out in") || paceText == "Lasts until reset")
        #expect(!paceText.contains("deficit"))
        #expect(!paceText.contains("reserve"))
        #expect(!paceText.contains("On pace"))
    }

    @Test
    func `claude spend cap on pace keeps the runs out text without a marker`() throws {
        let model = try Self.makeModel(cost: Self.cadencedCost(used: 67), showUsed: true)
        let section = try #require(model.providerCost)

        #expect(section.paceText == "Runs out in 9d 20h")
        #expect(section.pacePercent == nil)
    }

    @Test
    func `pace hides when pace is not visible`() throws {
        let model = try Self.makeModel(cost: Self.cadencedCost(used: 40), showUsed: true, paceVisible: false)
        let section = try #require(model.providerCost)

        #expect(section.resetText == "Resets in 10d")
        #expect(section.paceText == nil)
        #expect(section.pacePercent == nil)
        #expect(section.paceOnTop)
        #expect(section.spendLine == "Monthly cap: $40.00 / $100.00")
    }

    @Test
    func `inferred rollover carries a tooltip and a reported reset does not`() throws {
        let inferredModel = try Self.makeModel(cost: Self.cadencedCost(used: 40), showUsed: true)
        let inferred = try #require(inferredModel.providerCost)
        #expect(inferred.resetText == "Resets in 10d")
        #expect(inferred.resetTooltip ==
            "Inferred: Claude doesn't report this date. Monthly spend caps roll over at 00:00 UTC on the 1st.")

        let reported = Self.cost(
            used: 40,
            limit: 100,
            resetsAt: Self.monthRollover,
            windowMinutes: Self.juneMinutes)
        let reportedModel = try Self.makeModel(cost: reported, showUsed: true)
        let reportedSection = try #require(reportedModel.providerCost)
        #expect(reportedSection.resetText == "Resets in 10d")
        #expect(reportedSection.resetTooltip == nil)
    }

    @Test
    func `spend cap without a reported cadence shows no rollover cues`() throws {
        let resetOnly = Self.cost(used: 40, limit: 100, resetsAt: Self.monthRollover)
        let model = try Self.makeModel(cost: resetOnly, showUsed: true)
        let section = try #require(model.providerCost)

        #expect(section.resetText == nil)
        #expect(section.resetTooltip == nil)
        #expect(section.paceText == nil)
        #expect(section.pacePercent == nil)
    }

    @Test(arguments: [ProviderCostMenuCardStyle.generic, .clawRouter], [false, true])
    func `other capped provider costs keep used fill`(style: ProviderCostMenuCardStyle, showUsed: Bool) throws {
        let section = try #require(UsageMenuCardView.Model.providerCostSection(
            cost: Self.cost(used: 25, limit: 100),
            style: style,
            percentStyle: showUsed ? .used : .left,
            preferredCurrencyCode: "USD"))

        #expect(section.percentStyle == .used)
        #expect(section.percentUsed == 25)
        #expect(section.displayPercent == 25)
        #expect(section.progressAccessibilityLabel == "Extra usage spent")
        #expect(section.spendLine == "Monthly cap: $25.00 / $100.00")
        #expect(section.percentLine == "25% used")
    }

    private static func cost(
        used: Double,
        limit: Double,
        balance: Double? = nil,
        period: String = "Monthly cap",
        resetsAt: Date? = nil,
        windowMinutes: Int? = nil,
        resetsAtIsInferred: Bool? = nil) -> ProviderCostSnapshot
    {
        ProviderCostSnapshot(
            used: used,
            limit: limit,
            currencyCode: "USD",
            period: period,
            resetsAt: resetsAt,
            balance: balance,
            windowMinutes: windowMinutes,
            resetsAtIsInferred: resetsAtIsInferred,
            updatedAt: self.now)
    }

    private static func cadencedCost(used: Double) -> ProviderCostSnapshot {
        self.cost(
            used: used,
            limit: 100,
            resetsAt: self.monthRollover,
            windowMinutes: self.juneMinutes,
            resetsAtIsInferred: true)
    }

    private static func makeModel(
        cost: ProviderCostSnapshot?,
        showUsed: Bool,
        showOptional: Bool = true,
        isAdminAPI: Bool = false,
        costSummaryInlineEnabled: Bool = true,
        paceVisible: Bool = true) throws -> UsageMenuCardView.Model
    {
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: cost,
            updatedAt: self.now,
            identity: isAdminAPI ? ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Admin API") : nil)
        return UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: showUsed,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            costSummaryInlineEnabled: costSummaryInlineEnabled,
            showOptionalCreditsAndExtraUsage: showOptional,
            hidePersonalInfo: true,
            paceVisible: paceVisible,
            preferredCurrencyCode: "USD",
            now: self.now))
    }
}
