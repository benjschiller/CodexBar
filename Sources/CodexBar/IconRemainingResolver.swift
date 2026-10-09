import CodexBarCore
import Foundation

enum IconRemainingResolver {
    /// The renderer caches percentages in tenths. This is the smallest robust value that has a distinct cache
    /// key from zero while still rounding to a zero-pixel fill in the 30-pixel meter.
    private static let visibleZeroPercent = 0.1

    static func resolvedWindows(
        snapshot: UsageSnapshot,
        style: IconStyle,
        secondaryOverrideWindowID: String? = nil,
        now: Date = Date())
        -> (primary: RateWindow?, secondary: RateWindow?)
    {
        guard let provider = UsageProvider(rawValue: style.rawValue) else {
            return (primary: snapshot.primary, secondary: snapshot.secondary)
        }
        let windows = ProviderDescriptorRegistry.descriptor(for: provider).presentation.iconWindows(
            context: ProviderIconWindowContext(
                snapshot: snapshot,
                secondaryOverrideWindowID: secondaryOverrideWindowID,
                now: now))
        return (primary: windows.primary, secondary: windows.secondary)
    }

    /// The provider's quota layout, minus the empty reserved lane when the icon's lanes are spend caps: a spend
    /// budget is one meter, not a session lane awaiting a weekly partner.
    static func quotaLayoutPolicy(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        now: Date = Date()) -> IconRenderer.QuotaLayoutPolicy
    {
        let policy = IconRenderer.QuotaLayoutPolicy.provider(provider)
        guard let snapshot else { return policy }
        let windows = ProviderDescriptorRegistry.descriptor(for: provider).presentation.iconWindows(
            context: ProviderIconWindowContext(snapshot: snapshot, secondaryOverrideWindowID: nil, now: now))
        guard windows.lanesAreSpendCaps else { return policy }
        return IconRenderer.QuotaLayoutPolicy(
            reservesMissingSecondaryLane: false,
            treatsExhaustedSecondaryAsMissing: policy.treatsExhaustedSecondaryAsMissing)
    }

    static func resolvedPercents(
        snapshot: UsageSnapshot,
        style: IconStyle,
        showUsed: Bool,
        secondaryOverrideWindowID: String? = nil,
        now: Date = Date())
        -> (primary: Double?, secondary: Double?)
    {
        let windows = Self.resolvedWindows(
            snapshot: snapshot,
            style: style,
            secondaryOverrideWindowID: secondaryOverrideWindowID,
            now: now)
        var percents = (
            primary: showUsed ? windows.primary?.usedPercent : windows.primary?.remainingPercent,
            secondary: showUsed ? windows.secondary?.usedPercent : windows.secondary?.remainingPercent)
        // Provider style chooses both the usage lanes and provider-specific layout sentinels. This must also
        // apply when the visual rendering style is `.combined`, because the renderer receives provider policy
        // separately from its visual style.
        let presentation = UsageProvider(rawValue: style.rawValue)
            .map { ProviderDescriptorRegistry.descriptor(for: $0).presentation }
        if showUsed,
           presentation?.treatsExhaustedSecondaryIconWindowAsMissing == true,
           let secondary = windows.secondary
        {
            if secondary.remainingPercent <= 0 {
                // Preserve Warp's exhausted/no-bonus layout even though used percent is 100.
                percents.secondary = 0
            } else if percents.secondary == 0 {
                // A zero fill means "lane absent" to IconRenderer; keep an unused bonus lane visible.
                percents.secondary = self.visibleZeroPercent
            }
        }
        return percents
    }
}
