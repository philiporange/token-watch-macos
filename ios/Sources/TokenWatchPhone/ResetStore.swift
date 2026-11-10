import BackgroundTasks
import Foundation
import SwiftUI
import TokenWatchCore

@MainActor
final class ResetStore: ObservableObject {
    static let backgroundIdentifier = "com.philiporange.TokenWatchPhone.reset-refresh"
    @Published private(set) var tracker = ResetTracker()
    @Published private(set) var lastChecked: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var claude = ClaudeResetFeed()
    @Published private(set) var claudeChecked: Date?
    @Published private(set) var claudeErrorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var backgroundUnavailable = false

    private let client = CodexResetClient()
    private let claudeClient = ClaudeResetClient()
    private let notifications: ResetNotifications
    private let cacheURL = URL.applicationSupportDirectory.appendingPathComponent("codex-resets.json")
    private let claudeCacheURL = URL.applicationSupportDirectory.appendingPathComponent("claude-resets.json")
    private var nextCheck: Date = .distantPast
    private var nextClaudeCheck: Date = .distantPast
    private var failures = 0
    private var claudeFailures = 0

    private struct Cache: Codable {
        let tracker: ResetTracker
        let checkedAt: Date
    }

    private struct ClaudeCache: Codable {
        let feed: ClaudeResetFeed
        let checkedAt: Date
    }

    init(notifications: ResetNotifications) {
        self.notifications = notifications
        if let data = try? Data(contentsOf: cacheURL), let cached = try? JSONDecoder().decode(Cache.self, from: data) {
            tracker = cached.tracker
            lastChecked = cached.checkedAt
        }
        if let data = try? Data(contentsOf: claudeCacheURL),
           let cached = try? JSONDecoder().decode(ClaudeCache.self, from: data) {
            claude = cached.feed
            claudeChecked = cached.checkedAt
        }
    }

    var stale: Bool { lastChecked.map { Date.now.timeIntervalSince($0) > 900 } ?? true }
    var claudeStale: Bool { claudeChecked.map { Date.now.timeIntervalSince($0) > 1800 } ?? true }

    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        let checkCodex = force || Date.now >= nextCheck
        let checkClaude = force || Date.now >= nextClaudeCheck
        guard checkCodex || checkClaude else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let codexSucceeded = checkCodex ? await refreshCodex() : false
        let claudeSucceeded = checkClaude ? await refreshClaude() : false
        if codexSucceeded || claudeSucceeded {
            await notifications.synchronize(tracker, claude: claude)
        }
    }

    private func refreshCodex() async -> Bool {
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
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            failures = min(failures + 1, 5)
            nextCheck = Date.now.addingTimeInterval(min(900, 60 * pow(2, Double(failures - 1))))
            errorMessage = "Reset updates are unavailable. The last announcement is kept until confirmation arrives."
            return false
        }
    }

    private func refreshClaude() async -> Bool {
        do {
            let feed = try await claudeClient.fetch()
            try Task.checkCancellation()
            claude = feed
            claudeChecked = .now
            claudeFailures = 0
            nextClaudeCheck = Date.now.addingTimeInterval(300)
            claudeErrorMessage = nil
            let cached = ClaudeCache(feed: feed, checkedAt: .now)
            try FileManager.default.createDirectory(at: claudeCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(cached).write(to: claudeCacheURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            claudeFailures = min(claudeFailures + 1, 3)
            nextClaudeCheck = Date.now.addingTimeInterval(TimeInterval(min(900, 300 * claudeFailures)))
            claudeErrorMessage = "Claude reset updates are unavailable. Saved reports are kept."
            return false
        }
    }

    func enableNotifications() async {
        await notifications.enable()
        guard notifications.enabled else { return }
        if stale || claudeStale { await refresh(force: true) }
        else { await notifications.synchronize(tracker, claude: claude) }
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
