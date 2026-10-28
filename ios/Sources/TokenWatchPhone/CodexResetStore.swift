import BackgroundTasks
import Foundation
import SwiftUI
import TokenWatchCore

@MainActor
final class CodexResetStore: ObservableObject {
    static let backgroundIdentifier = "com.philiporange.TokenWatchPhone.reset-refresh"
    @Published private(set) var tracker = ResetTracker()
    @Published private(set) var lastChecked: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var backgroundUnavailable = false

    private let client = CodexResetClient()
    private let notifications: ResetNotifications
    private let cacheURL = URL.applicationSupportDirectory.appendingPathComponent("codex-resets.json")
    private var nextCheck: Date = .distantPast
    private var failures = 0

    private struct Cache: Codable {
        let tracker: ResetTracker
        let checkedAt: Date
    }

    init(notifications: ResetNotifications) {
        self.notifications = notifications
        if let data = try? Data(contentsOf: cacheURL), let cached = try? JSONDecoder().decode(Cache.self, from: data) {
            tracker = cached.tracker
            lastChecked = cached.checkedAt
        }
    }

    var stale: Bool { lastChecked.map { Date.now.timeIntervalSince($0) > 900 } ?? true }

    func refresh(force: Bool = false) async {
        guard !isRefreshing, force || Date.now >= nextCheck else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let result = try await client.fetch(tracker: tracker)
            try Task.checkCancellation()
            tracker.apply(result.status, history: result.history, now: .now)
            lastChecked = .now
            failures = 0
            nextCheck = Date.now.addingTimeInterval(60)
            errorMessage = nil
            let cached = Cache(tracker: tracker, checkedAt: .now)
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(cached).write(to: cacheURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            await notifications.synchronize(tracker)
        } catch {
            guard !Task.isCancelled else { return }
            failures = min(failures + 1, 5)
            nextCheck = Date.now.addingTimeInterval(min(900, 60 * pow(2, Double(failures - 1))))
            errorMessage = "Reset updates are unavailable. The last announcement is kept until confirmation arrives."
        }
    }

    func enableNotifications() async {
        await notifications.enable()
        guard notifications.enabled else { return }
        if stale { await refresh(force: true) }
        else { await notifications.synchronize(tracker) }
        scheduleBackgroundRefresh()
    }

    func scheduleBackgroundRefresh(hasConnection: Bool = false) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundIdentifier)
        guard notifications.enabled || hasConnection else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundIdentifier)
        request.earliestBeginDate = Date.now.addingTimeInterval(900)
        do {
            try BGTaskScheduler.shared.submit(request)
            backgroundUnavailable = false
        } catch {
            backgroundUnavailable = true
        }
    }
}
