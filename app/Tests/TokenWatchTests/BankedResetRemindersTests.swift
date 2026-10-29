import Foundation
import Testing
@testable import TokenWatch

@MainActor
private final class FakeBankedResetNotificationScheduler: BankedResetNotificationScheduling {
    var status: BankedResetNotificationAuthorization = .authorized
    var statusAfterRequest: BankedResetNotificationAuthorization = .authorized
    var pending: Set<String> = []
    var added: [BankedResetNotice] = []
    var removed: Set<String> = []
    var authorizationRequests = 0
    var statusReads = 0
    var suspendAuthorization = false
    var authorizationContinuation: CheckedContinuation<Void, Never>?

    func authorizationStatus() async -> BankedResetNotificationAuthorization {
        statusReads += 1
        return status
    }

    func requestAuthorization() async throws {
        authorizationRequests += 1
        if suspendAuthorization {
            await withCheckedContinuation { authorizationContinuation = $0 }
        }
        status = statusAfterRequest
    }

    func pendingIdentifiers() async -> Set<String> { pending }
    func add(_ notice: BankedResetNotice, now: Date) async throws {
        added.append(notice)
        pending.insert(notice.id)
    }
    func remove(identifiers: Set<String>) async {
        removed.formUnion(identifiers)
        pending.subtract(identifiers)
    }
}

@Suite @MainActor struct BankedResetRemindersTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func reset(_ id: String = "credit_1", seconds: Double = 172800,
                       status: String = "available", usable: Bool = true, note: String? = nil) -> BankedReset {
        .init(id: id, title: "Full reset", expiresAt: now.addingTimeInterval(seconds),
              status: status, usable: usable, note: note)
    }

    private func snapshot(_ resets: [BankedReset], provider: ProviderKind = .claude) -> ProviderSnapshot {
        var snapshot = makeSnapshot(provider, fiveHourUsed: 50)
        snapshot.bankedResets = resets
        return snapshot
    }

    private func plan(_ resets: [BankedReset], autoApply: Bool = false, lead: Int = 5) -> BankedResetReminderPlan {
        .init(snapshots: [snapshot(resets)], autoApplyEnabled: autoApply, leadMinutes: lead, now: now)
    }

    private func coordinator(_ scheduler: FakeBankedResetNotificationScheduler,
                             enabled: Bool = true) -> BankedResetReminderCoordinator {
        let name = "banked-reminders-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(enabled, forKey: BankedResetReminderCoordinator.enabledKey)
        let coordinator = BankedResetReminderCoordinator(scheduler: scheduler, userDefaults: defaults)
        defaults.removePersistentDomain(forName: name)
        coordinator.snapshots = [snapshot([reset()])]
        return coordinator
    }

    @Test func allOffsetsIdentifiersAndTitles() {
        let result = plan([reset()])
        let expiry = now.addingTimeInterval(172800)
        let offsets = [1440, 720, 240, 60, 15]
        #expect(result.notices.map(\.fireAt) == offsets.map { expiry.addingTimeInterval(-Double($0) * 60) })
        #expect(result.notices.map(\.id) == offsets.map {
            "tokenwatch.banked.claude.credit_1.\($0).\(Int(expiry.timeIntervalSince1970))"
        })
        #expect(result.activeIDs == Set(result.notices.map(\.id)))
        #expect(result.notices.map(\.title) == ["24 hours", "12 hours", "4 hours", "1 hour", "15 minutes"].map {
            "Claude reset expires in \($0)"
        })
        let codex = BankedResetReminderPlan(snapshots: [snapshot([reset()], provider: .codex)],
            autoApplyEnabled: false, leadMinutes: 5, now: now)
        #expect(codex.notices.first?.id.contains(".codex.") == true)
        #expect(codex.notices.first?.title == "Codex reset expires in 24 hours")
    }

    @Test func onlyFutureOffsetsWithOneSecondGrace() {
        let result = plan([reset(seconds: 10800)])
        #expect(result.notices.map(\.fireAt) == [now.addingTimeInterval(7200), now.addingTimeInterval(9900)])
        #expect(plan([reset(seconds: 901)]).notices.isEmpty)
        #expect(plan([reset(seconds: 901.1)]).notices.count == 1)
    }

    @Test func excludesExpiredConsumedAndUndatedResets() {
        var undated = reset("undated")
        undated.expiresAt = nil
        let result = plan([reset("past", seconds: -1), reset("now", seconds: 0),
            reset("expired", status: "expired"), reset("redeemed", status: "redeemed"),
            reset("redeeming", status: "redeeming"), undated])
        #expect(result.notices.isEmpty && result.activeIDs.isEmpty)
        for status in ["paused", "unavailable", "unknown"] {
            #expect(plan([reset(status: status, usable: false)]).notices.count == 5)
        }
        #expect(BankedResetReminderPlan(snapshots: [snapshot([reset()], provider: .gemini)],
            autoApplyEnabled: false, leadMinutes: 5, now: now).notices.isEmpty)
    }

    @Test func bodyUsesAutomaticManualAndUnavailableWording() throws {
        let expiry = now.addingTimeInterval(172800).formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "en")))
        let prefix = "“Full reset” expires \(expiry)."
        #expect(try #require(plan([reset()], autoApply: true, lead: 7).notices.first).body ==
            prefix + " Token Watch will apply it automatically 7 minutes before it expires.")
        #expect(try #require(plan([reset()]).notices.first).body ==
            prefix + " Apply it from the Token Watch menu before then.")
        #expect(try #require(plan([reset(usable: false, note: "Use Claude Desktop.")], autoApply: true).notices.first).body ==
            prefix + " Use Claude Desktop.")
        #expect(try #require(plan([reset(usable: false)]).notices.first).body == prefix)
    }

    @Test func capsEightResetsAcrossProvidersInExpiryOrder() {
        let resets = (1...10).reversed().map { reset("credit_\($0)", seconds: Double($0) * 172800) }
        let result = BankedResetReminderPlan(snapshots: [snapshot(Array(resets.prefix(5))),
            snapshot(Array(resets.suffix(5)), provider: .codex)], autoApplyEnabled: false, leadMinutes: 5, now: now)
        #expect(result.notices.count == 40)
        #expect(stride(from: 0, to: 40, by: 5).map { result.notices[$0].id.components(separatedBy: ".")[3] } ==
            (1...8).map { "credit_\($0)" })
    }

    @Test func everyLanguageHasReminderStrings() {
        for language in AppLanguage.allCases {
            let loc = Loc(lang: language)
            #expect(!loc.bankedResetRemindersEnable.isEmpty)
            #expect(!loc.bankedResetRemindersCaption.isEmpty)
            #expect(!loc.bankedResetRemindersDenied.isEmpty)
            let localized = BankedResetReminderPlan(snapshots: [snapshot([reset()])],
                autoApplyEnabled: true, leadMinutes: 7, now: now, loc: loc)
            #expect(localized.notices.count == 5)
            #expect(localized.notices.allSatisfy { !$0.title.isEmpty && $0.body.contains("7") })
            #expect(!loc.bankedResetReminderManual.isEmpty)
        }
    }

    @Test func requestsAuthorizationOnlyOnceWhenNeeded() async {
        let scheduler = FakeBankedResetNotificationScheduler()
        scheduler.status = .notDetermined
        scheduler.statusAfterRequest = .notDetermined
        let coordinator = coordinator(scheduler)
        coordinator.snapshots = []
        await coordinator.synchronize(now: now)
        #expect(scheduler.authorizationRequests == 0)
        coordinator.snapshots = [snapshot([reset()])]
        await coordinator.synchronize(now: now)
        await coordinator.synchronize(now: now)
        #expect(scheduler.authorizationRequests == 1)
        #expect(scheduler.added.isEmpty)
    }

    @Test func grantedAuthorizationSchedulesAndKeepsOtherIdentifiers() async {
        let scheduler = FakeBankedResetNotificationScheduler()
        scheduler.status = .notDetermined
        let coordinator = coordinator(scheduler)
        let planned = plan([reset()])
        scheduler.pending = ["tokenwatch.banked.obsolete", planned.notices[0].id, "tokenwatch.other", "other.app"]
        await coordinator.synchronize(now: now)
        #expect(scheduler.authorizationRequests == 1)
        #expect(coordinator.authorization == .authorized)
        #expect(scheduler.added == planned.notices)
        #expect(scheduler.removed == ["tokenwatch.banked.obsolete"])
        #expect(scheduler.pending == planned.activeIDs.union(["tokenwatch.other", "other.app"]))
        coordinator.snapshots = []
        await coordinator.synchronize(now: now)
        #expect(scheduler.pending == ["tokenwatch.other", "other.app"])
    }

    @Test func disabledRemovesAllBankedRequestsEvenWhenDenied() async {
        let scheduler = FakeBankedResetNotificationScheduler()
        scheduler.status = .denied
        scheduler.pending = ["tokenwatch.banked.one", "tokenwatch.banked.two", "tokenwatch.unrelated"]
        let coordinator = coordinator(scheduler, enabled: false)
        await coordinator.synchronize(now: now)
        #expect(scheduler.pending == ["tokenwatch.unrelated"])
        #expect(scheduler.removed == ["tokenwatch.banked.one", "tokenwatch.banked.two"])
        #expect(scheduler.added.isEmpty && scheduler.authorizationRequests == 0)
    }

    @Test func deniedAuthorizationDoesNotScheduleOrAskAgain() async {
        let scheduler = FakeBankedResetNotificationScheduler()
        scheduler.status = .denied
        let coordinator = coordinator(scheduler)
        await coordinator.synchronize(now: now)
        #expect(coordinator.authorization == .denied)
        #expect(scheduler.added.isEmpty && scheduler.authorizationRequests == 0)
    }

    @Test func synchronizationsRemainSerializedDuringAuthorization() async {
        let scheduler = FakeBankedResetNotificationScheduler()
        scheduler.status = .notDetermined
        scheduler.suspendAuthorization = true
        let coordinator = coordinator(scheduler)
        let first = Task { await coordinator.synchronize(now: now) }
        while scheduler.authorizationContinuation == nil { await Task.yield() }
        let second = Task { await coordinator.synchronize(now: now) }
        for _ in 0..<10 { await Task.yield() }
        #expect(scheduler.statusReads == 1)
        scheduler.authorizationContinuation?.resume()
        await first.value
        await second.value
        #expect(scheduler.authorizationRequests == 1)
        #expect(scheduler.added.count == 10)
    }

    @Test func defaultEnabledSettingIsPersisted() async {
        let name = "banked-reminders-default-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let scheduler = FakeBankedResetNotificationScheduler()
        let coordinator = BankedResetReminderCoordinator(scheduler: scheduler, userDefaults: defaults)
        #expect(coordinator.enabled)
        coordinator.enabled = false
        await coordinator.synchronize(now: now)
        #expect(defaults.object(forKey: "bankedResetRemindersEnabled") as? Bool == false)
        #expect(!BankedResetReminderCoordinator(scheduler: scheduler, userDefaults: defaults).enabled)
    }

    @Test func storeUpdatesReminderInputsForSnapshotsAndAutoApplySettings() async {
        let name = "banked-reminders-store-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let scheduler = FakeBankedResetNotificationScheduler()
        var claudeReset = reset()
        claudeReset.expiresAt = Date.now.addingTimeInterval(3 * 86400)
        var codexReset = reset("codex")
        codexReset.expiresAt = Date.now.addingTimeInterval(4 * 86400)
        let claude = snapshot([claudeReset])
        let codex = snapshot([codexReset], provider: .codex)
        let store = UsageStore(claudeProbe: ProbeStub(queue: ProbeQueue([claude])),
            codexProbe: ProbeStub(queue: ProbeQueue([codex])), userDefaults: defaults,
            startRefreshLoop: false, resetAppliers: [:], notificationScheduler: scheduler)
        await store.refresh(.claude)
        #expect(store.bankedResetReminders.snapshots[0].bankedResets == [claudeReset])
        await store.refresh(.codex)
        #expect(store.bankedResetReminders.snapshots[1].bankedResets == [codexReset])
        store.bankedResetAutoApplyEnabled = true
        store.bankedResetAutoApplyLeadMinutes = 9
        await store.bankedResetReminders.synchronize()
        #expect(store.bankedResetReminders.snapshots.flatMap(\.bankedResets).count == 2)
        #expect(store.bankedResetReminders.autoApplyEnabled)
        #expect(store.bankedResetReminders.leadMinutes == 9)
        #expect(scheduler.added.suffix(10).allSatisfy { $0.body.contains("automatically 9 minutes") })
        #expect(scheduler.pending.count == 10)
    }
}
