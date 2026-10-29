import SwiftUI
import TokenWatchCore
import UserNotifications

/// Maintains local expiry notifications independently of the public announcement alerts.
@MainActor
final class BankedResetReminders: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var errorMessage: String?

    private let center = UNUserNotificationCenter.current()
    private let defaultsKey = "bankedResetRemindersEnabled"
    private var isSyncing = false
    private var needsSync = false
    private var requestedAuthorization = false
    private var latestSnapshot: UsageSnapshot?

    init() {
        enabled = UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    var permitted: Bool { [.authorized, .provisional, .ephemeral].contains(authorization) }

    func setEnabled(_ value: Bool, snapshot: UsageSnapshot?) async {
        enabled = value
        UserDefaults.standard.set(value, forKey: defaultsKey)
        if value { await requestAuthorizationIfNeeded() }
        await synchronize(snapshot)
    }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    private func requestAuthorizationIfNeeded() async {
        await refreshAuthorization()
        guard enabled, authorization == .notDetermined, !requestedAuthorization else { return }
        requestedAuthorization = true
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
            errorMessage = nil
        } catch {
            errorMessage = "Notifications could not be enabled. Please try again."
        }
        await refreshAuthorization()
    }

    func synchronize(_ snapshot: UsageSnapshot?) async {
        latestSnapshot = snapshot
        needsSync = true
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        while needsSync {
            needsSync = false
            let plan = BankedResetReminderPlan.make(providers: latestSnapshot?.providers ?? [],
                                                    autoApply: latestSnapshot?.autoApply, now: .now)
            await refreshAuthorization()
            if enabled, !plan.notices.isEmpty { await requestAuthorizationIfNeeded() }
            let existing = await center.pendingNotificationRequests()
            let obsolete = existing.map(\.identifier).filter {
                $0.hasPrefix(BankedResetReminderPlan.prefix) && (!enabled || !permitted || !plan.activeIDs.contains($0))
            }
            center.removePendingNotificationRequests(withIdentifiers: obsolete)
            guard enabled, permitted else { continue }
            for notice in plan.notices {
                guard enabled, !needsSync, !Task.isCancelled else { break }
                let delay = notice.fireAt.timeIntervalSinceNow
                guard delay > 1 else { continue }
                let content = UNMutableNotificationContent()
                content.title = notice.title
                content.body = notice.body
                content.sound = .default
                content.threadIdentifier = "banked-resets"
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
                do {
                    try await center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: trigger))
                    errorMessage = nil
                } catch {
                    errorMessage = "A reset reminder could not be scheduled. It will be retried after the next reading."
                }
            }
        }
    }
}
