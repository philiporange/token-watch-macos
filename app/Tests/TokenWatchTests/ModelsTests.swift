import Foundation
import Testing
@testable import TokenWatch

@Suite struct ModelsTests {

    // MARK: - UsagePacing

    @Test func pacingDeltaWeeklyAndMonthly() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let weekly = makeWindow(.weekly, used: 40, resetsAt: now.addingTimeInterval(3.5 * 86_400))
        let weeklyDelta = try! #require(UsagePacing.delta(for: weekly, now: now))
        #expect(abs(weeklyDelta - 10) < 0.0001)
        #expect(UsagePacing.formattedDelta(for: weekly, now: now) == "+10%")

        let monthly = makeWindow(.monthly, used: 35, resetsAt: now.addingTimeInterval(15 * 86_400))
        let monthlyDelta = try! #require(UsagePacing.delta(for: monthly, now: now))
        #expect(abs(monthlyDelta - 15) < 0.0001)

        let fiveHour = makeWindow(.fiveHour, used: 40, resetsAt: now.addingTimeInterval(3.5 * 86_400))
        #expect(UsagePacing.delta(for: fiveHour, now: now) == nil)
        #expect(UsagePacing.formattedDelta(for: fiveHour, now: now) == nil)
    }

    // MARK: - pacingWindow selection

    @Test func pacingWindowSelection() {
        let model65 = ModelUsageWindow(
            modelName: "m",
            window: makeWindow(.modelWeekly, used: 65),
            isActive: false
        )
        let s1 = makeSnapshot(.claude, weeklyUsed: 40, modelWindows: [model65])
        #expect(s1.pacingWindow.usedPercentage == 65)

        let s2 = makeSnapshot(.claude, weeklyUsed: 80, modelWindows: [model65])
        #expect(s2.pacingWindow.usedPercentage == 80)
    }

    // MARK: - MenuBarVisibility: ticked / visible defaults

    @Test func defaultTickedAndVisible() {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let snap = makeSnapshot(.claude, fiveHourUsed: 10)
        #expect(MenuBarVisibility.isTicked(.claude, userDefaults: defaults) == true)
        #expect(MenuBarVisibility.showsInMenuBar(snap, userDefaults: defaults) == true)

        defaults.set(false, forKey: MenuBarVisibility.defaultsKey(for: .claude))
        #expect(MenuBarVisibility.isTicked(.claude, userDefaults: defaults) == false)
        #expect(MenuBarVisibility.showsInMenuBar(snap, userDefaults: defaults) == false)
    }

    // MARK: - MenuBarVisibility: pace reveal

    @Test func paceReveal() {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let now = Date()
        defaults.set(false, forKey: MenuBarVisibility.defaultsKey(for: .claude))
        defaults.set(true, forKey: MenuBarVisibility.paceRevealEnabledKey)

        // delta ≈ +10 with default +10/-10: strict comparisons → no reveal.
        let plus10 = makeSnapshot(.claude, weeklyUsed: 40, weeklyReset: now.addingTimeInterval(3.5 * 86_400))
        #expect(MenuBarVisibility.showsInMenuBar(plus10, userDefaults: defaults, now: now) == false)

        // above = 5 → +10 > 5 → reveal.
        defaults.set(5.0, forKey: MenuBarVisibility.paceRevealAboveKey)
        #expect(MenuBarVisibility.showsInMenuBar(plus10, userDefaults: defaults, now: now) == true)

        // above = 50, below = -5, snapshot 70% used (delta -20) → -20 < -5 → reveal.
        defaults.set(50.0, forKey: MenuBarVisibility.paceRevealAboveKey)
        defaults.set(-5.0, forKey: MenuBarVisibility.paceRevealBelowKey)
        let minus20 = makeSnapshot(.claude, weeklyUsed: 70, weeklyReset: now.addingTimeInterval(3.5 * 86_400))
        #expect(MenuBarVisibility.showsInMenuBar(minus20, userDefaults: defaults, now: now) == true)
    }

    // MARK: - MenuBarVisibility: reset reveal

    @Test func resetReveal() {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(false, forKey: MenuBarVisibility.defaultsKey(for: .claude))

        let low = makeSnapshot(.claude, weeklyUsed: 2)
        #expect(MenuBarVisibility.showsInMenuBar(low, userDefaults: defaults) == false)

        defaults.set(true, forKey: MenuBarVisibility.resetRevealEnabledKey)
        #expect(MenuBarVisibility.showsInMenuBar(low, userDefaults: defaults) == true)

        // 5% exactly: strict "<" → still hidden.
        let exactly5 = makeSnapshot(.claude, weeklyUsed: 5)
        #expect(MenuBarVisibility.showsInMenuBar(exactly5, userDefaults: defaults) == false)

        // threshold 10 → 5 < 10 → reveal.
        defaults.set(10.0, forKey: MenuBarVisibility.resetRevealBelowKey)
        #expect(MenuBarVisibility.showsInMenuBar(exactly5, userDefaults: defaults) == true)

        // no usage data → never reveals.
        let noData = makeSnapshot(.claude)
        #expect(MenuBarVisibility.showsInMenuBar(noData, userDefaults: defaults) == false)
    }

    // MARK: - MenuBarVisibility: nearing-reset reveal

    @Test func nearingResetReveal() {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let now = Date()
        defaults.set(false, forKey: MenuBarVisibility.defaultsKey(for: .claude))
        defaults.set(true, forKey: MenuBarVisibility.nearingResetRevealEnabledKey)

        let near = makeSnapshot(.claude, weeklyUsed: 50, weeklyReset: now.addingTimeInterval(12 * 3_600))
        #expect(MenuBarVisibility.showsInMenuBar(near, userDefaults: defaults, now: now) == true)

        let far = makeSnapshot(.claude, weeklyUsed: 50, weeklyReset: now.addingTimeInterval(2 * 86_400))
        #expect(MenuBarVisibility.showsInMenuBar(far, userDefaults: defaults, now: now) == false)

        defaults.set(72.0, forKey: MenuBarVisibility.nearingResetRevealHoursKey)
        #expect(MenuBarVisibility.showsInMenuBar(far, userDefaults: defaults, now: now) == true)

        let noReset = makeSnapshot(.claude, weeklyUsed: 50)
        #expect(MenuBarVisibility.showsInMenuBar(noReset, userDefaults: defaults, now: now) == false)
    }

    // MARK: - AgentAvailability

    @Test func agentAvailabilityShowsInPopover() {
        #expect(AgentAvailability.loading.showsInPopover == true)
        #expect(AgentAvailability.available.showsInPopover == true)
        #expect(AgentAvailability.notInstalled.showsInPopover == false)
        #expect(AgentAvailability.error("x").showsInPopover == false)
    }

    // MARK: - AutoRefreshInterval

    @Test func autoRefreshInterval() {
        #expect(AutoRefreshInterval.defaultValue == .fiveMinutes)
        #expect(AutoRefreshInterval.manual.label == "Manual")
        #expect(AutoRefreshInterval.tenMinutes.label == "10 minutes")
        #expect(AutoRefreshInterval.thirtyMinutes.duration == 1800)
    }

    // MARK: - z.ai MCP hiding & synthetic weekly

    @Test func zaiShowsLongWindowAndPacingFallback() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fiveHourReset = now.addingTimeInterval(2 * 3600)
        let monthlyReset = now.addingTimeInterval(15 * 86_400)
        let snap = ProviderSnapshot(
            provider: .zai,
            fiveHour: makeWindow(.fiveHour, used: 25, resetsAt: fiveHourReset),
            weekly: makeWindow(.monthly, used: 80, resetsAt: monthlyReset),
            modelWindows: [],
            detail: nil
        )

        // !showsLongWindow
        #expect(snap.showsLongWindow == false)

        // pacingWindow's kind, value, and reset equal fiveHour
        #expect(snap.pacingWindow.kind == .fiveHour)
        #expect(snap.pacingWindow.usedPercentage == 25)
        #expect(snap.pacingWindow.resetsAt == fiveHourReset)

        // raw weekly monthly remains available
        #expect(snap.weekly.kind == .monthly)
        #expect(snap.weekly.usedPercentage == 80)
        #expect(snap.weekly.resetsAt == monthlyReset)

        // loading zai has !showsLongWindow and pacingWindow equal fiveHour
        let loadingSnap = ProviderSnapshot.loading(.zai)
        #expect(loadingSnap.showsLongWindow == false)
        #expect(loadingSnap.pacingWindow.kind == .fiveHour)

        // other providers with monthly preserve showsLongWindow and pacingWindow
        let museSnap = ProviderSnapshot(
            provider: .muse,
            fiveHour: makeWindow(.fiveHour, used: 10),
            weekly: makeWindow(.monthly, used: 50, resetsAt: monthlyReset),
            modelWindows: [],
            detail: nil
        )
        #expect(museSnap.showsLongWindow == true)
        #expect(museSnap.pacingWindow.kind == .monthly)
    }

    @Test func zaiNoMcpPaceReveal() {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        defaults.set(false, forKey: MenuBarVisibility.defaultsKey(for: .zai))
        defaults.set(true, forKey: MenuBarVisibility.paceRevealEnabledKey)
        defaults.set(5.0, forKey: MenuBarVisibility.paceRevealAboveKey)

        // z.ai has monthly MCP reset that would trigger pace reveal if evaluated, but pacingWindow is fiveHour
        let snap = ProviderSnapshot(
            provider: .zai,
            fiveHour: makeWindow(.fiveHour, used: 10),
            weekly: makeWindow(.monthly, used: 40, resetsAt: now.addingTimeInterval(3.5 * 86_400)),
            modelWindows: [],
            detail: nil
        )
        // With fiveHour pacing window, UsagePacing.delta is nil, so no pace reveal occurs
        #expect(MenuBarVisibility.showsInMenuBar(snap, userDefaults: defaults, now: now) == false)

        // Preserve other-provider behavior: claude with weekly pace triggers reveal
        defaults.set(false, forKey: MenuBarVisibility.defaultsKey(for: .claude))
        let claudeSnap = makeSnapshot(.claude, weeklyUsed: 40, weeklyReset: now.addingTimeInterval(3.5 * 86_400))
        #expect(MenuBarVisibility.showsInMenuBar(claudeSnap, userDefaults: defaults, now: now) == true)
    }
}
