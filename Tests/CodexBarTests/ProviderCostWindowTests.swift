import Foundation
import Testing
@testable import CodexBarCore

struct ProviderCostWindowTests {
    @Test(arguments: [(-5.0, 0.0), (0, 0), (25, 25), (100, 100), (150, 100)])
    func `spend budget meters clamp usage and retain reset metadata`(used: Double, expected: Double) throws {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let cost = ProviderCostSnapshot(used: used, limit: 100, currencyCode: "USD", resetsAt: reset, updatedAt: reset)
        let window = try #require(cost.spendLimitWindow)
        #expect(window.usedPercent == expected)
        #expect(window.resetsAt == reset)
        #expect(window.windowMinutes == nil)
        #expect(window.resetDescription == nil)
        #expect(!window.isSyntheticPlaceholder)
    }

    @Test
    func `spend limit window carries the cost cadence`() throws {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let cost = ProviderCostSnapshot(
            used: 25,
            limit: 100,
            currencyCode: "USD",
            resetsAt: reset,
            windowMinutes: 31 * 24 * 60,
            updatedAt: reset)
        let window = try #require(cost.spendLimitWindow)
        #expect(window.windowMinutes == 31 * 24 * 60)
        #expect(window.resetsAt == reset)
    }

    @Test
    func `balance replacement keeps the cost cadence`() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let cost = ProviderCostSnapshot(
            used: 25,
            limit: 100,
            currencyCode: "USD",
            resetsAt: reset,
            windowMinutes: 28 * 24 * 60,
            updatedAt: reset)
        #expect(cost.replacing(balance: 5).windowMinutes == 28 * 24 * 60)
    }

    @Test
    func `legacy cost snapshots decode without a window cadence`() throws {
        let json = """
        {
            "used": 12.5,
            "limit": 100,
            "currencyCode": "USD",
            "period": "Monthly cap",
            "resetsAt": 800000000,
            "updatedAt": 0
        }
        """
        let legacy = try JSONDecoder().decode(ProviderCostSnapshot.self, from: Data(json.utf8))
        #expect(legacy.windowMinutes == nil)
        #expect(legacy.spendLimitWindow?.windowMinutes == nil)

        let encodedLegacy = try JSONEncoder().encode(legacy)
        let object = try #require(JSONSerialization.jsonObject(with: encodedLegacy) as? [String: Any])
        #expect(object["windowMinutes"] == nil)

        let current = ProviderCostSnapshot(
            used: 12.5,
            limit: 100,
            currencyCode: "USD",
            resetsAt: Date(timeIntervalSince1970: 1_800_000_000),
            windowMinutes: 30 * 24 * 60,
            updatedAt: Date(timeIntervalSince1970: 0))
        let roundTripped = try JSONDecoder().decode(ProviderCostSnapshot.self, from: JSONEncoder().encode(current))
        #expect(roundTripped == current)
        #expect(roundTripped.windowMinutes == 30 * 24 * 60)
    }

    @Test
    func `legacy cost snapshots decode without the inferred flag`() throws {
        let json = """
        {
            "used": 12.5,
            "limit": 100,
            "currencyCode": "USD",
            "period": "Monthly cap",
            "resetsAt": 800000000,
            "windowMinutes": 43200,
            "updatedAt": 0
        }
        """
        let legacy = try JSONDecoder().decode(ProviderCostSnapshot.self, from: Data(json.utf8))
        #expect(legacy.resetsAtIsInferred == nil)

        let encodedLegacy = try JSONEncoder().encode(legacy)
        let object = try #require(JSONSerialization.jsonObject(with: encodedLegacy) as? [String: Any])
        #expect(object["resetsAtIsInferred"] == nil)

        let inferred = ProviderCostSnapshot(
            used: 12.5,
            limit: 100,
            currencyCode: "USD",
            resetsAt: Date(timeIntervalSince1970: 1_800_000_000),
            windowMinutes: 30 * 24 * 60,
            resetsAtIsInferred: true,
            updatedAt: Date(timeIntervalSince1970: 0))
        let roundTripped = try JSONDecoder().decode(ProviderCostSnapshot.self, from: JSONEncoder().encode(inferred))
        #expect(roundTripped == inferred)
        #expect(roundTripped.resetsAtIsInferred == true)
        #expect(inferred.replacing(balance: 5).resetsAtIsInferred == true)
    }

    @Test(arguments: [0.0, -1.0, Double.nan])
    func `balance only or invalid limits never become quota meters`(limit: Double) {
        let cost = ProviderCostSnapshot(used: 10, limit: limit, currencyCode: "USD", updatedAt: .now)
        #expect(cost.spendLimitWindow == nil)
    }
}
