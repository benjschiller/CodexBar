import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension StatusItemAnimationSignatureTests {
    @Test
    func `merged icon redraws when the spend lane layout changes`() throws {
        let suite = "StatusItemAnimationSignatureTests-merged-spend-lane-layout"
        let settings = testSettingsStore(suiteName: suite)
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.menuBarShowsBrandIconWithPercent = false
        settings.usageBarsShowUsed = true
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
        defer { controller.releaseStatusItemsForTesting() }

        store._setSnapshotForTesting(Self.spendOnlyClaudeSnapshot(), provider: .claude)
        #expect(controller.applyIcon(phase: nil) == false)
        let spendOnlySignature = try #require(controller.lastAppliedMergedIconRenderSignature)

        store._setSnapshotForTesting(Self.sessionOnlyClaudeSnapshot(), provider: .claude)
        #expect(controller.applyIcon(phase: nil) == false)
        let quotaSignature = try #require(controller.lastAppliedMergedIconRenderSignature)

        for signature in [spendOnlySignature, quotaSignature] {
            #expect(signature.contains("primary=25.000"))
            #expect(signature.contains("weekly=nil"))
        }
        #expect(spendOnlySignature != quotaSignature)
        #expect(controller.applyIcon(phase: nil) == true)
    }

    @Test
    func `split provider icon redraws when the spend lane layout changes`() throws {
        let suite = "StatusItemAnimationSignatureTests-split-spend-lane-layout"
        let settings = testSettingsStore(suiteName: suite)
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.menuBarShowsBrandIconWithPercent = false
        settings.usageBarsShowUsed = true
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
        defer { controller.releaseStatusItemsForTesting() }

        store._setSnapshotForTesting(Self.spendOnlyClaudeSnapshot(), provider: .claude)
        #expect(controller.applyIcon(for: .claude, phase: nil) == false)
        let spendOnlySignature = try #require(controller.lastAppliedProviderIconRenderSignatures[.claude])

        store._setSnapshotForTesting(Self.sessionOnlyClaudeSnapshot(), provider: .claude)
        #expect(controller.applyIcon(for: .claude, phase: nil) == false)
        let quotaSignature = try #require(controller.lastAppliedProviderIconRenderSignatures[.claude])

        for signature in [spendOnlySignature, quotaSignature] {
            #expect(signature.contains("primary=25.000"))
            #expect(signature.contains("weekly=nil"))
        }
        #expect(spendOnlySignature != quotaSignature)
        #expect(controller.applyIcon(for: .claude, phase: nil) == true)
    }

    /// Same 25% top lane as `sessionOnlyClaudeSnapshot`, so only the spend lane layout can tell them apart.
    private static func spendOnlyClaudeSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 25,
                limit: 100,
                currencyCode: "USD",
                period: "Spend limit",
                updatedAt: Date()),
            updatedAt: Date())
    }

    private static func sessionOnlyClaudeSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
    }
}
