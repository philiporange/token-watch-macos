import SwiftUI
import TokenWatchCore
import UserNotifications

@MainActor
final class ResetNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "resetAlertsEnabled")
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var reminderCount = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var testSent = false
    @Published var openDetails = false
    @Published var openBankedProvider: String?

    private let center = UNUserNotificationCenter.current()
    private let ledgerKey = "resetNotificationLedger"
    private var ledger: ResetNotificationLedger
    private var isSyncing = false

    override init() {
        ledger = UserDefaults.standard.data(forKey: "resetNotificationLedger")
            .flatMap { try? JSONDecoder().decode(ResetNotificationLedger.self, from: $0) } ?? ResetNotificationLedger()
        super.init()
        center.delegate = self
    }

    var permitted: Bool { [.authorized, .provisional, .ephemeral].contains(authorization) }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
        reminderCount = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(ResetNotificationPlan.prefix + "reminder.") }.count
    }

    func enable() async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            enabled = granted
            UserDefaults.standard.set(granted, forKey: "resetAlertsEnabled")
            errorMessage = nil
        } catch {
            errorMessage = "Notifications could not be enabled. Please try again."
        }
        await refreshAuthorization()
    }

    func disable() async {
        enabled = false
        UserDefaults.standard.set(false, forKey: "resetAlertsEnabled")
        let pending = await center.pendingNotificationRequests()
        let own = pending.map(\.identifier).filter { $0.hasPrefix(ResetNotificationPlan.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: own)
        ledger.forget(Set(own.filter { $0.hasPrefix(ResetNotificationPlan.prefix + "reminder.") }))
        persistLedger()
        reminderCount = 0
    }

    func synchronize(_ tracker: ResetTracker, now: Date = .now) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        await refreshAuthorization()
        guard enabled, permitted else { return }
        let plan = ResetNotificationPlan.make(tracker: tracker, ledger: ledger, now: now)
        let existing = await center.pendingNotificationRequests()
        let obsolete = existing.map(\.identifier).filter {
            $0.hasPrefix(ResetNotificationPlan.prefix) && $0 != ResetNotificationPlan.prefix + "test" && !plan.activeIDs.contains($0)
        }
        center.removePendingNotificationRequests(withIdentifiers: obsolete)
        ledger.forget(Set(obsolete.filter { $0.hasPrefix(ResetNotificationPlan.prefix + "reminder.") }))
        for notice in plan.notices {
            guard enabled, !Task.isCancelled else { break }
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            content.sound = .default
            content.threadIdentifier = "codex-resets"
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, notice.fireAt.timeIntervalSinceNow), repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: trigger))
                guard enabled else {
                    center.removePendingNotificationRequests(withIdentifiers: [notice.id])
                    break
                }
                ledger.record(notice.id)
                persistLedger()
                errorMessage = nil
            } catch {
                errorMessage = "A reset reminder could not be scheduled. It will be retried on the next successful check."
            }
        }
        persistLedger()
        await refreshAuthorization()
    }

    func sendTest() async {
        guard enabled, permitted else { return }
        let content = UNMutableNotificationContent()
        content.title = "Token Watch test"
        content.body = "Reset alerts are enabled on this iPhone."
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: ResetNotificationPlan.prefix + "test", content: content,
                                                       trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)))
            testSent = true
        } catch {
            errorMessage = "The test notification could not be scheduled."
        }
    }

    private func persistLedger() {
        if let data = try? JSONEncoder().encode(ledger) { UserDefaults.standard.set(data, forKey: ledgerKey) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        Task { @MainActor in
            if identifier.hasPrefix(BankedResetReminderPlan.prefix) {
                self.openBankedProvider = identifier.dropFirst(BankedResetReminderPlan.prefix.count)
                    .split(separator: ".").first.map(String.init)
            } else {
                self.openDetails = true
            }
        }
        completionHandler()
    }
}
