import Foundation
import Testing
@testable import TokenWatch

@Suite @MainActor struct UsageStoreTests {

    private func freshDefaults() -> (UserDefaults, String) {
        let suite = "test-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func stub(_ snapshot: ProviderSnapshot) -> ProbeStub {
        ProbeStub(queue: ProbeQueue([snapshot]))
    }

    // MARK: - agentStatus / visibleSnapshots

    @Test func agentStatusAndVisibleSnapshots() async {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = UsageStore(
            claudeProbe: stub(makeSnapshot(.claude, fiveHourUsed: 10)),
            codexProbe: stub(makeSnapshot(
                .codex,
                fiveHourMessage: "codex is not installed or not on PATH.",
                weeklyMessage: "codex is not installed or not on PATH."
            )),
            userDefaults: defaults,
            startRefreshLoop: false
        )
        await store.refresh()

        #expect(store.agentStatus(for: .claude).availability == .available)
        #expect(store.agentStatus(for: .codex).availability == .notInstalled)

        let providers = store.visibleSnapshots.map(\.provider)
        #expect(providers.contains(.claude))
        #expect(!providers.contains(.codex))
    }

    // MARK: - Rate-limit preservation

    @Test func rateLimitPreservesPreviousData() async {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let claudeQueue = ProbeQueue([
            makeSnapshot(.claude, fiveHourUsed: 20),
            makeSnapshot(.claude, fiveHourMessage: "HTTP 429 rate limit exceeded"),
        ])
        let codexQueue = ProbeQueue([
            makeSnapshot(.codex, fiveHourUsed: 5),
            makeSnapshot(.codex, fiveHourUsed: 8),
        ])
        let store = UsageStore(
            claudeProbe: ProbeStub(queue: claudeQueue),
            codexProbe: ProbeStub(queue: codexQueue),
            userDefaults: defaults,
            startRefreshLoop: false
        )

        await store.refresh()
        #expect(store.claude.fiveHour.usedPercentage == 20)

        await store.refresh()
        #expect(store.claude.fiveHour.usedPercentage == 20)
        #expect(store.codex.fiveHour.usedPercentage == 8)
        #expect(store.lastUpdated != nil)
    }

    // MARK: - Transient-auth forgiveness

    @Test func transientAuthForgiveness() async {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let claudeQueue = ProbeQueue([
            makeSnapshot(.claude, fiveHourUsed: 30),
            makeSnapshot(.claude, fiveHourMessage: "Claude authentication failed."),
        ])
        let store = UsageStore(
            claudeProbe: ProbeStub(queue: claudeQueue),
            codexProbe: stub(makeSnapshot(.codex, fiveHourUsed: 5)),
            userDefaults: defaults,
            startRefreshLoop: false
        )

        await store.refresh()
        #expect(store.claude.fiveHour.usedPercentage == 30)

        // First auth failure is forgiven.
        await store.refresh()
        #expect(store.claude.fiveHour.usedPercentage == 30)
        #expect(store.agentStatus(for: .claude).availability == .available)

        // Second consecutive failure surfaces.
        await store.refresh()
        #expect(store.claude.fiveHour.usedPercentage == nil)
        #expect(store.agentStatus(for: .claude).availability == .sessionExpired)
    }

    // MARK: - Per-provider refresh

    @Test func perProviderRefresh() async {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = UsageStore(
            claudeProbe: stub(makeSnapshot(.claude, fiveHourUsed: 42)),
            codexProbe: stub(makeSnapshot(.codex, fiveHourUsed: 7)),
            userDefaults: defaults,
            startRefreshLoop: false
        )

        await store.refresh(.claude)
        #expect(store.claude.fiveHour.usedPercentage == 42)
        #expect(store.codex.fiveHour.usedPercentage == nil)
        #expect(store.lastUpdatedByProvider[.claude] != nil)
        #expect(store.lastUpdated != nil)
        #expect(store.isRefreshing == false)
    }

    // MARK: - Auto-refresh interval + loop

    @Test func manualLoopThenSwitchToTimed() async {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0, forKey: "autoRefreshInterval") // manual

        let counter = CallCounter()
        let store = UsageStore(
            claudeProbe: CountingProbe(snapshot: makeSnapshot(.claude, fiveHourUsed: 10), counter: counter),
            codexProbe: stub(makeSnapshot(.codex, fiveHourUsed: 5)),
            userDefaults: defaults,
            startRefreshLoop: true
        )

        #expect(store.autoRefreshInterval == .manual)
        let reachedOne = await waitUntil { await counter.count >= 1 }
        #expect(reachedOne)

        // Manual → no further refreshes.
        try? await Task.sleep(for: .milliseconds(200))
        let afterWait = await counter.count
        #expect(afterWait == 1)

        // Switch to timed → persists and triggers an immediate refresh.
        store.setAutoRefreshInterval(.oneMinute)
        #expect(store.autoRefreshInterval == .oneMinute)
        #expect(defaults.integer(forKey: "autoRefreshInterval") == 60)

        let grew = await waitUntil { await counter.count >= 2 }
        #expect(grew)

        withExtendedLifetime(store) {}
    }

    // MARK: - Launch at startup

    @Test func launchAtStartupReflectsAndToggles() async {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let spy = LaunchAtStartupManagerSpy()
        spy.state = .enabled
        let store = UsageStore(
            claudeProbe: stub(makeSnapshot(.claude)),
            codexProbe: stub(makeSnapshot(.codex)),
            launchAtStartupManager: spy,
            userDefaults: defaults,
            startRefreshLoop: false
        )

        #expect(store.launchAtStartupState == .enabled)
        #expect(store.launchAtStartupEnabled == true)

        store.setLaunchAtStartupEnabled(false)
        #expect(spy.setEnabledCalls == [false])
        #expect(store.launchAtStartupState == .disabled)
        #expect(store.launchAtStartupErrorMessage == nil)
    }

    @Test func launchAtStartupThrowingSetsError() async {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let spy = LaunchAtStartupManagerSpy()
        spy.state = .disabled
        spy.failure = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "nope"])
        let store = UsageStore(
            claudeProbe: stub(makeSnapshot(.claude)),
            codexProbe: stub(makeSnapshot(.codex)),
            launchAtStartupManager: spy,
            userDefaults: defaults,
            startRefreshLoop: false
        )

        store.setLaunchAtStartupEnabled(true)
        #expect(store.launchAtStartupErrorMessage != nil)
        #expect(store.launchAtStartupState == .disabled)
    }
}
