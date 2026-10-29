import Foundation
import SwiftUI
import UserNotifications

struct BankedResetNotice: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let body: String
    let fireAt: Date
}

struct BankedResetReminderPlan {
    static let identifierPrefix = "tokenwatch.banked."
    let notices: [BankedResetNotice]
    var activeIDs: Set<String> { Set(notices.map(\.id)) }

    init(snapshots: [ProviderSnapshot], autoApplyEnabled: Bool, leadMinutes: Int,
         now: Date, loc: Loc = Loc()) {
        let eligible = snapshots.filter { $0.provider == .claude || $0.provider == .codex }
            .flatMap { snapshot in snapshot.bankedResets.map { (snapshot.provider, $0) } }
            .filter { _, reset in
                guard let expiry = reset.expiresAt else { return false }
                return expiry > now && !["expired", "redeemed", "redeeming"].contains(reset.status)
            }
            .sorted { lhs, rhs in
                if lhs.1.expiresAt != rhs.1.expiresAt { return lhs.1.expiresAt! < rhs.1.expiresAt! }
                return (lhs.0.routeKey, lhs.1.id) < (rhs.0.routeKey, rhs.1.id)
            }.prefix(8)
        notices = eligible.flatMap { provider, reset -> [BankedResetNotice] in
            let expiry = reset.expiresAt!
            let date = expiry.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened)
                .locale(Locale(identifier: loc.lang.rawValue)))
            var body = loc.bankedResetReminderExpiry(title: reset.title, date: date)
            if reset.usable {
                body += " " + (autoApplyEnabled
                    ? loc.bankedResetReminderAutomatic(minutes: min(60, max(1, leadMinutes)))
                    : loc.bankedResetReminderManual)
            } else if let note = reset.note {
                body += " " + note
            }
            return [1440, 720, 240, 60, 15].compactMap { minutes in
                let fireAt = expiry.addingTimeInterval(-Double(minutes) * 60)
                guard fireAt > now.addingTimeInterval(1) else { return nil }
                return BankedResetNotice(
                    id: "\(Self.identifierPrefix)\(provider.routeKey).\(reset.id).\(minutes).\(Int(expiry.timeIntervalSince1970))",
                    title: loc.bankedResetReminderTitle(provider: provider.rawValue, minutes: minutes),
                    body: body, fireAt: fireAt)
            }
        }
    }
}

enum BankedResetNotificationAuthorization: Equatable {
    case notDetermined, denied, authorized
}

@MainActor
protocol BankedResetNotificationScheduling {
    func authorizationStatus() async -> BankedResetNotificationAuthorization
    func requestAuthorization() async throws
    func pendingIdentifiers() async -> Set<String>
    func add(_ notice: BankedResetNotice, now: Date) async throws
    func remove(identifiers: Set<String>) async
}

@MainActor
struct NoOpBankedResetNotificationScheduler: BankedResetNotificationScheduling {
    func authorizationStatus() async -> BankedResetNotificationAuthorization { .denied }
    func requestAuthorization() async throws {}
    func pendingIdentifiers() async -> Set<String> { [] }
    func add(_ notice: BankedResetNotice, now: Date) async throws {}
    func remove(identifiers: Set<String>) async {}
}

@MainActor
private final class LiveBankedResetNotificationScheduler: NSObject,
    BankedResetNotificationScheduling, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    var onReminderClicked: (@MainActor () -> Void)?

    init(center: UNUserNotificationCenter) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func authorizationStatus() async -> BankedResetNotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func requestAuthorization() async throws {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
    }

    func pendingIdentifiers() async -> Set<String> {
        Set(await center.pendingNotificationRequests().map(\.identifier))
    }

    func add(_ notice: BankedResetNotice, now: Date) async throws {
        // Use the scheduling clock so a long authorization prompt cannot delay expiry reminders.
        let interval = notice.fireAt.timeIntervalSince(Date.now)
        guard interval > 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier: notice.id, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)))
    }

    func remove(identifiers: Set<String>) async {
        center.removePendingNotificationRequests(withIdentifiers: Array(identifiers))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              response.notification.request.identifier.hasPrefix(BankedResetReminderPlan.identifierPrefix) else { return }
        await MainActor.run { onReminderClicked?() }
    }
}

@MainActor
func makeBankedResetNotificationScheduler() -> any BankedResetNotificationScheduling {
    guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else {
        return NoOpBankedResetNotificationScheduler()
    }
    return LiveBankedResetNotificationScheduler(center: .current())
}

@MainActor
final class BankedResetReminderCoordinator: ObservableObject {
    static let enabledKey = "bankedResetRemindersEnabled"
    @Published var enabled: Bool {
        didSet {
            userDefaults.set(enabled, forKey: Self.enabledKey)
            Task { await synchronize() }
        }
    }
    @Published private(set) var authorization: BankedResetNotificationAuthorization = .notDetermined
    var snapshots: [ProviderSnapshot] = []
    var autoApplyEnabled = false
    var leadMinutes = 5
    var language: AppLanguage = .english
    var onReminderClicked: (@MainActor () -> Void)? {
        didSet { (scheduler as? LiveBankedResetNotificationScheduler)?.onReminderClicked = onReminderClicked }
    }
    private let scheduler: any BankedResetNotificationScheduling
    private let userDefaults: UserDefaults
    private var requestedAuthorization = false
    private var syncTask: Task<Void, Never>?
    private var syncGeneration = 0

    init(scheduler: any BankedResetNotificationScheduling, userDefaults: UserDefaults = .standard) {
        self.scheduler = scheduler
        self.userDefaults = userDefaults
        enabled = userDefaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func synchronize(now: Date = .now) async {
        let previous = syncTask
        syncGeneration += 1
        let generation = syncGeneration
        let task = Task { @MainActor in
            await previous?.value
            await self.performSynchronization(now: now)
        }
        syncTask = task
        await task.value
        if generation == syncGeneration { syncTask = nil }
    }

    private func performSynchronization(now: Date) async {
        authorization = await scheduler.authorizationStatus()
        let pending = await scheduler.pendingIdentifiers()
        let banked = pending.filter { $0.hasPrefix(BankedResetReminderPlan.identifierPrefix) }
        guard enabled else {
            await scheduler.remove(identifiers: banked)
            return
        }
        let plan = BankedResetReminderPlan(snapshots: snapshots, autoApplyEnabled: autoApplyEnabled,
            leadMinutes: leadMinutes, now: now, loc: Loc(lang: language))
        if !plan.notices.isEmpty, authorization == .notDetermined, !requestedAuthorization {
            requestedAuthorization = true
            try? await scheduler.requestAuthorization()
            authorization = await scheduler.authorizationStatus()
        }
        guard enabled, authorization == .authorized else { return }
        await scheduler.remove(identifiers: banked.subtracting(plan.activeIDs))
        for notice in plan.notices {
            guard enabled else { return }
            try? await scheduler.add(notice, now: now)
        }
    }
}
