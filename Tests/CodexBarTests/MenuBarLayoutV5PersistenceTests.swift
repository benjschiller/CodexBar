import Foundation
import Testing
@testable import CodexBar

struct MenuBarLayoutV5PersistenceTests {
    private static let spendLayout = MenuBarLayout(lines: [[
        .icon,
        .percent(window: .spend),
        .pace(window: .spend),
        .windowResetCountdown(window: .spend),
        .spendAmount,
        .spendBudget,
        .extraPercent(id: "cursor-grok-bot"),
        .windowResetCountdown(window: .weekly),
    ]])

    /// What a 0.73.0 build reads back: Spend tokens drop out, named extras and reset windows stay.
    private static let v4Projection = MenuBarLayout(lines: [[
        .icon,
        .extraPercent(id: "cursor-grok-bot"),
        .windowResetCountdown(window: .weekly),
    ]])

    @Test
    func `unchanged downgrade retains spend tokens on return`() throws {
        let layout = Self.spendLayout
        let layouts = try MenuBarLayoutPersistence.encoded(layout)
        let overrides = try MenuBarLayoutPersistence.encodedOverrides(["claude": layout])
        let readable = Self.rule(metric: .session, thenToken: .resetCountdown)
        let spendMetric = Self.rule(metric: .spend, thenToken: .providerName)
        let spendBranch = Self.rule(metric: .session, thenToken: .percent(window: .spend))
        let library = [readable, spendMetric, spendBranch]
        let libraryBlobs = try MenuBarLayoutPersistence.encodedLibrary(library)
        let decoder = JSONDecoder()

        #expect(try MenuBarLayoutPersistence.preferredLayout(
            current: decoder.decode(MenuBarLayout.self, from: layouts.current),
            v4: decoder.decode(MenuBarLayout.self, from: layouts.v4),
            v3: decoder.decode(MenuBarLayout.self, from: layouts.v3),
            released: decoder.decode(MenuBarLayout.self, from: layouts.released),
            legacy: decoder.decode(MenuBarLayout.self, from: layouts.legacy)) == layout)
        #expect(try MenuBarLayoutPersistence.preferredOverrides(
            current: decoder.decode([String: MenuBarLayout].self, from: overrides.current),
            v4: decoder.decode([String: MenuBarLayout].self, from: overrides.v4),
            v3: decoder.decode([String: MenuBarLayout].self, from: overrides.v3),
            released: decoder.decode([String: MenuBarLayout].self, from: overrides.released),
            legacy: decoder.decode([String: MenuBarLayout].self, from: overrides.legacy)) == ["claude": layout])
        #expect(try MenuBarLayoutPersistence.preferredLibrary(
            current: decoder.decode([MenuBarLayoutConditional].self, from: libraryBlobs.current),
            v4: decoder.decode([MenuBarLayoutConditional].self, from: libraryBlobs.v4),
            v3: decoder.decode([MenuBarLayoutConditional].self, from: libraryBlobs.v3),
            released: decoder.decode([MenuBarLayoutConditional].self, from: libraryBlobs.released),
            legacy: decoder.decode([MenuBarLayoutConditional].self, from: libraryBlobs.legacy)) == library)
    }

    @Test
    func `V4 projection drops spend tokens but keeps named extras and reset windows`() throws {
        let overrides = [
            "claude": Self.spendLayout,
            "cursor": MenuBarLayout(lines: [[.spendBudget, .windowResetAbsolute(window: .session)]]),
        ]
        let decoder = JSONDecoder()
        let layoutBlobs = try MenuBarLayoutPersistence.encoded(Self.spendLayout)
        let overrideBlobs = try MenuBarLayoutPersistence.encodedOverrides(overrides)

        #expect(try decoder.decode(MenuBarLayout.self, from: layoutBlobs.current) == Self.spendLayout)
        #expect(Self.spendLayout.v4Compatible() == Self.v4Projection)
        #expect(try decoder.decode(ReleasedV4Layout.self, from: layoutBlobs.v4)
            == ReleasedV4Layout(lines: [[
                .icon, .extraPercent(id: "cursor-grok-bot"), .windowResetCountdown(window: .weekly),
            ]]))
        let projectedOverrides = try decoder.decode([String: ReleasedV4Layout].self, from: overrideBlobs.v4)
        #expect(projectedOverrides["claude"] == ReleasedV4Layout(lines: [[
            .icon, .extraPercent(id: "cursor-grok-bot"), .windowResetCountdown(window: .weekly),
        ]]))
        #expect(projectedOverrides["cursor"] == ReleasedV4Layout(lines: [[.windowResetAbsolute(window: .session)]]))
        // V3 loses the named extra as well, and every older generation loses the Spend tokens too.
        #expect(try decoder.decode(MenuBarLayout.self, from: layoutBlobs.v3)
            == MenuBarLayout(lines: [[.icon, .windowResetCountdown(window: .weekly)]]))
        #expect(try decoder.decode(MenuBarLayout.self, from: layoutBlobs.released) == MenuBarLayout(lines: [[.icon]]))
        // The V5 blob alone is unreadable to a V4 decoder: that is why V5 lives under its own key.
        #expect(throws: DecodingError.self) {
            try decoder.decode(ReleasedV4Layout.self, from: layoutBlobs.current)
        }
        #expect(throws: DecodingError.self) {
            try decoder.decode([String: ReleasedV4Layout].self, from: overrideBlobs.current)
        }
    }

    @Test
    func `loading without V5 uses V4 and not V3`() {
        let defaults = InMemoryUserDefaults()
        let expected = Self.v4Projection
        let rule = Self.rule(metric: .session, thenToken: .extraPercent(id: "cursor-grok-bot"))

        let loaded = MenuBarLayoutPersistence.loadLayout(
            current: nil,
            v4: expected,
            v3: expected.v3Compatible(),
            released: expected.releasedCompatible(),
            legacy: expected.legacyCompatible(),
            into: defaults)
        let loadedOverrides = MenuBarLayoutPersistence.loadOverrides(
            current: nil,
            v4: ["cursor": expected],
            v3: ["cursor": expected.v3Compatible()],
            released: ["cursor": expected.releasedCompatible()],
            legacy: ["cursor": expected.legacyCompatible()],
            into: defaults)
        let loadedLibrary = MenuBarLayoutPersistence.loadLibrary(
            current: nil,
            v4: [rule],
            v3: [],
            released: [],
            legacy: [],
            into: defaults)

        #expect(loaded == expected)
        #expect(loadedOverrides == ["cursor": expected])
        #expect(loadedLibrary == [rule])
        for key in [
            MenuBarLayoutUserDefaultsKey.layoutCurrent, MenuBarLayoutUserDefaultsKey.layoutV4,
            MenuBarLayoutUserDefaultsKey.overridesCurrent, MenuBarLayoutUserDefaultsKey.overridesV4,
            MenuBarLayoutUserDefaultsKey.conditionalsCurrent, MenuBarLayoutUserDefaultsKey.conditionalsV4,
        ] {
            #expect(defaults.data(forKey: key) != nil, "\(key)")
        }
    }

    @Test
    func `storage keys keep V4 readable for 0_73_0 and put the current layout under V5`() {
        #expect(MenuBarLayoutUserDefaultsKey.layoutCurrent == "menuBarLayoutV5")
        #expect(MenuBarLayoutUserDefaultsKey.layoutV4 == "menuBarLayoutV4")
        #expect(MenuBarLayoutUserDefaultsKey.overridesCurrent == "menuBarLayoutOverridesV5")
        #expect(MenuBarLayoutUserDefaultsKey.overridesV4 == "menuBarLayoutOverridesV4")
        #expect(MenuBarLayoutUserDefaultsKey.conditionalsCurrent == "menuBarLayoutConditionalsV5")
        #expect(MenuBarLayoutUserDefaultsKey.conditionalsV4 == "menuBarLayoutConditionalsV4")
    }

    @Test
    func `V4 edits win on return upgrade across layouts overrides and conditionals`() {
        let fullLayout = Self.spendLayout
        let olderLayoutEdit = MenuBarLayout(lines: [[.icon, .windowResetCountdown(window: .session)]])
        #expect(MenuBarLayoutPersistence.preferredLayout(
            current: fullLayout,
            v4: olderLayoutEdit,
            v3: olderLayoutEdit.v3Compatible(),
            released: olderLayoutEdit.releasedCompatible(),
            legacy: olderLayoutEdit.legacyCompatible()) == olderLayoutEdit)

        let fullOverrides = ["cursor": fullLayout, "claude": fullLayout]
        let olderOverrideEdit = ["cursor": olderLayoutEdit]
        #expect(MenuBarLayoutPersistence.preferredOverrides(
            current: fullOverrides,
            v4: olderOverrideEdit,
            v3: olderOverrideEdit.mapValues { $0.v3Compatible() },
            released: olderOverrideEdit.mapValues { $0.releasedCompatible() },
            legacy: olderOverrideEdit.mapValues { $0.legacyCompatible() }) == olderOverrideEdit)

        let readable = Self.rule(metric: .session, thenToken: .windowResetCountdown(window: .weekly))
        let spendRule = Self.rule(metric: .spend, thenToken: .percent(window: .spend))
        let olderConditionalEdit = MenuBarLayoutConditional(
            id: readable.id,
            name: "Edited in 0.73.0",
            clauses: readable.clauses,
            thenToken: .windowResetAbsolute(window: .session),
            elseToken: .hidden)
        #expect(MenuBarLayoutPersistence.preferredLibrary(
            current: [readable, spendRule],
            v4: [olderConditionalEdit],
            v3: [olderConditionalEdit],
            released: [],
            legacy: []) == [olderConditionalEdit, spendRule])

        // A 0.73.0 user clearing the library deliberately clears the Spend rules too.
        #expect(MenuBarLayoutPersistence.preferredLibrary(
            current: [readable, spendRule],
            v4: [],
            v3: [],
            released: [],
            legacy: []) == [])
    }

    @Test
    func `conditionals reading spend metrics are omitted from older libraries`() throws {
        let readable = Self.rule(metric: .session, thenToken: .resetCountdown)
        let spendPercent = Self.rule(metric: .spend, thenToken: .providerName)
        let spendResets = Self.rule(metric: .spendResetsIn, thenToken: .providerName)
        let spendPace = Self.rule(metric: .spendPace, thenToken: .providerName)
        let spendAmount = Self.rule(metric: .spendAmount, thenToken: .providerName)
        let spendThen = Self.rule(metric: .session, thenToken: .percent(window: .spend))
        let spendElse = Self.rule(metric: .session, thenToken: .providerName, elseToken: .spendBudget)
        let spendRules = [spendPercent, spendResets, spendPace, spendAmount, spendThen, spendElse]
        let library = [readable] + spendRules

        for rule in spendRules {
            #expect(rule.v4Compatible == nil)
            #expect(rule.v3Compatible == nil)
            #expect(rule.releasedCompatible == nil)
            #expect(rule.legacyCompatible == nil)
        }
        #expect(readable.v4Compatible != nil)

        let blobs = try MenuBarLayoutPersistence.encodedLibrary(library)
        let decoder = JSONDecoder()
        for blob in [blobs.v4, blobs.v3, blobs.released, blobs.legacy] {
            #expect(try decoder.decode([MenuBarLayoutConditional].self, from: blob).map(\.id) == [readable.id])
            // Dropped up front rather than left for the old decoder to choke on.
            #expect(try decoder.decode([ReleasedV4Conditional].self, from: blob).map(\.id) == [readable.id])
        }
        #expect(try decoder.decode([MenuBarLayoutConditional].self, from: blobs.current).count == library.count)
        let lenient = try decoder.decode([LenientReleasedV4Conditional].self, from: blobs.current)
        #expect(lenient.compactMap(\.value).map(\.id) == [readable.id])
    }

    @Test
    func `the shipped spend conditional stays out of every older generation`() throws {
        let shipped = MenuBarLayoutConditional.shippedLibrary()
        let spend = try #require(shipped.first { $0.thenToken == .percent(window: .spend) })
        let others = shipped.filter { $0.id != spend.id }
        let blobs = try MenuBarLayoutPersistence.encodedLibrary(shipped)
        let decoder = JSONDecoder()

        #expect(try decoder.decode([MenuBarLayoutConditional].self, from: blobs.current).count == shipped.count)
        // The V4 projection decodes cleanly in a frozen 0.73.0 reader, holding every other shipped rule.
        let projected = try decoder.decode([ReleasedV4Conditional].self, from: blobs.v4)
        #expect(Set(projected.map(\.id)) == Set(others.map(\.id)))
        #expect(try decoder.decode([MenuBarLayoutConditional].self, from: blobs.v3).map(\.id)
            .contains(spend.id) == false)
        #expect(try decoder.decode([MenuBarLayoutConditional].self, from: blobs.released).map(\.id)
            .contains(spend.id) == false)
        #expect(try decoder.decode([MenuBarLayoutConditional].self, from: blobs.legacy).map(\.id)
            .contains(spend.id) == false)
    }

    @Test
    func `a spend only layout projects to the default layout`() throws {
        let spendOnly = MenuBarLayout(lines: [[.percent(window: .spend), .spendBudget]])
        let decoder = JSONDecoder()
        let blobs = try MenuBarLayoutPersistence.encoded(spendOnly)
        let overrideBlobs = try MenuBarLayoutPersistence.encodedOverrides(["claude": spendOnly])

        for blob in [blobs.v4, blobs.v3, blobs.released, blobs.legacy] {
            #expect(try decoder.decode(MenuBarLayout.self, from: blob) == .defaultLayout)
        }
        #expect(try decoder.decode(ReleasedV4Layout.self, from: blobs.v4)
            == ReleasedV4Layout(lines: [[.icon, .percent(window: .automatic)]]))
        #expect(try decoder.decode([String: MenuBarLayout].self, from: overrideBlobs.v4)["claude"] == .defaultLayout)

        // The default is only the older generations' stand-in: returning to this build restores the layout.
        #expect(try MenuBarLayoutPersistence.preferredLayout(
            current: decoder.decode(MenuBarLayout.self, from: blobs.current),
            v4: decoder.decode(MenuBarLayout.self, from: blobs.v4),
            v3: decoder.decode(MenuBarLayout.self, from: blobs.v3),
            released: decoder.decode(MenuBarLayout.self, from: blobs.released),
            legacy: decoder.decode(MenuBarLayout.self, from: blobs.legacy)) == spendOnly)

        // A second line emptied by the projection is dropped rather than left blank for the older reader.
        let stacked = MenuBarLayout(lines: [[.icon], [.percent(window: .spend)]])
        #expect(stacked.v4Compatible() == MenuBarLayout(lines: [[.icon]]))
    }

    private static func rule(
        metric: MenuBarConditionalMetric,
        thenToken: MenuBarLayoutToken,
        elseToken: MenuBarLayoutToken = .hidden)
        -> MenuBarLayoutConditional
    {
        MenuBarLayoutConditional(
            clauses: [MenuBarConditionalClause(
                combinator: nil,
                predicate: MenuBarConditionalPredicate(metric: metric, comparison: .greaterThan, threshold: 50))],
            thenToken: thenToken,
            elseToken: elseToken)
    }
}

/// Frozen 0.73.0 decoder surface. Its `PercentWindow` has no `spend` case, and a synthesized `Codable` enum throws on
/// any unknown case, so a Spend token in a blob it reads would lose the whole layout.
private enum ReleasedV4PercentWindow: String, Codable, Equatable {
    case session
    case weekly
    case scopedWeekly
    case automatic
}

private enum ReleasedV4Token: Codable, Equatable {
    case icon
    case providerName
    case accountLabel
    case percent(window: ReleasedV4PercentWindow)
    case lanePercent(lane: MenuBarLayoutLane)
    case extraPercent(id: String)
    case pace(window: ReleasedV4PercentWindow)
    case usageBar
    case resetCountdown
    case resetAbsolute
    case windowResetCountdown(window: ReleasedV4PercentWindow)
    case windowResetAbsolute(window: ReleasedV4PercentWindow)
    case runsOut
    case runsOutCompact
    case balance
    case costToday
    case cost30d
    case separatorDot
    case space
    case hidden
    case conditional(id: UUID)
}

private struct ReleasedV4Layout: Codable, Equatable {
    let lines: [[ReleasedV4Token]]
}

private enum ReleasedV4Metric: String, Codable {
    case session
    case weekly
    case scopedWeekly
    case automatic
    case primaryLane
    case secondaryLane
    case tertiaryLane
    case sessionResetsIn
    case weeklyResetsIn
    case scopedWeeklyResetsIn
    case automaticResetsIn
    case sessionPace
    case weeklyPace
    case automaticPace
    case runsOutIn
    case balance
    case costToday
    case cost30d
}

private struct ReleasedV4Conditional: Decodable {
    struct Clause: Decodable {
        struct Predicate: Decodable {
            let metric: ReleasedV4Metric
        }

        let predicate: Predicate
    }

    let id: UUID
    let clauses: [Clause]
    let thenToken: ReleasedV4Token
    let elseToken: ReleasedV4Token
}

/// 0.73.0 decodes the library element-wise: an entry it cannot read is dropped on its own.
private struct LenientReleasedV4Conditional: Decodable {
    let value: ReleasedV4Conditional?

    init(from decoder: Decoder) throws {
        self.value = try? ReleasedV4Conditional(from: decoder)
    }
}
