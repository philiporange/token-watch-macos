import Foundation
import SwiftUI

protocol ProviderSnapshotFetching: Sendable {
    func fetch() async -> ProviderSnapshot
}

extension ClaudeProbe: ProviderSnapshotFetching {}
extension CodexProbe: ProviderSnapshotFetching {}
extension GeminiProbe: ProviderSnapshotFetching {}
extension ZaiProbe: ProviderSnapshotFetching {}
extension MuseProbe: ProviderSnapshotFetching {}
extension AliCloudProbe: ProviderSnapshotFetching {}
extension CommandCodeProbe: ProviderSnapshotFetching {}

private struct MissingGeminiSnapshotFetcher: ProviderSnapshotFetching {
    func fetch() async -> ProviderSnapshot {
        let message = "Gemini credentials not found. Run agy and sign in."
        return ProviderSnapshot(
            provider: .gemini,
            fiveHour: .placeholder(.fiveHour, message: message),
            weekly: .placeholder(.weekly, message: message)
        )
    }
}

private struct MissingZaiSnapshotFetcher: ProviderSnapshotFetching {
    func fetch() async -> ProviderSnapshot {
        let message = "Z.ai API key not found. Set ZAI_API_KEY in ~/.env."
        return ProviderSnapshot(
            provider: .zai,
            fiveHour: .placeholder(.fiveHour, message: message),
            weekly: .placeholder(.monthly, message: message)
        )
    }
}

private struct MissingMuseSnapshotFetcher: ProviderSnapshotFetching {
    func fetch() async -> ProviderSnapshot {
        let message = "Muse credentials not found. Run muse login."
        return ProviderSnapshot(
            provider: .muse,
            fiveHour: .placeholder(.fiveHour, message: message),
            weekly: .placeholder(.weekly, message: message)
        )
    }
}

private struct MissingAliCloudSnapshotFetcher: ProviderSnapshotFetching {
    func fetch() async -> ProviderSnapshot {
        let message = AliCloudError.credentialsNotFound.localizedDescription
        return ProviderSnapshot(
            provider: .alicloud,
            fiveHour: .placeholder(.fiveHour, message: message),
            weekly: .placeholder(.weekly, message: message)
        )
    }
}

private struct MissingCommandCodeSnapshotFetcher: ProviderSnapshotFetching {
    func fetch() async -> ProviderSnapshot {
        let message = CommandCodeError.credentialsNotFound.localizedDescription
        return ProviderSnapshot(
            provider: .commandCode,
            fiveHour: .placeholder(.fiveHour, message: message),
            weekly: .placeholder(.weekly, message: message)
        )
    }
}

@MainActor
final class UsageStore: ObservableObject {
    static let bankedResetAutoApplyEnabledKey = "bankedResetAutoApplyEnabled"
    static let bankedResetAutoApplyLeadMinutesKey = "bankedResetAutoApplyLeadMinutes"
    private static let resetKeysKey = "bankedResetIdempotencyKeys"

    @Published var bankedResetAutoApplyEnabled: Bool {
        didSet {
            userDefaults.set(bankedResetAutoApplyEnabled, forKey: Self.bankedResetAutoApplyEnabledKey)
            restartAutoApplyLoop()
            synchronizeBankedResetReminders()
        }
    }
    @Published var bankedResetAutoApplyLeadMinutes: Int {
        didSet {
            let clamped = min(60, max(1, bankedResetAutoApplyLeadMinutes))
            if clamped != bankedResetAutoApplyLeadMinutes { bankedResetAutoApplyLeadMinutes = clamped }
            userDefaults.set(clamped, forKey: Self.bankedResetAutoApplyLeadMinutesKey)
            synchronizeBankedResetReminders()
        }
    }
    @Published private(set) var lastAutoApplyResult: BankedResetAutoApplyResult?
    @Published private(set) var applyingBankedResets: Set<String> = []
    @Published private(set) var bankedResetMessages: [String: String] = [:]
    @Published private(set) var bankedResetResultRows: [String: BankedReset] = [:]
    private let resetAppliers: [ProviderKind: any BankedResetApplying]
    private var resetTasks: [String: Task<BankedResetApplyResult, Never>] = [:]
    private var autoApplyLoopTask: Task<Void, Never>?
    private var autoApplyTickRunning = false
    private var resetCompleted: Set<String> = []
    private var resetAttempts: [String: Date] = [:]
    private let runsAutoApplyLoop: Bool

    private static let autoRefreshIntervalKey = "autoRefreshInterval"

    let bankedResetReminders: BankedResetReminderCoordinator

    @Published var claude: ProviderSnapshot = .loading(.claude) {
        didSet { synchronizeBankedResetReminders() }
    }
    @Published var codex: ProviderSnapshot = .loading(.codex) {
        didSet { synchronizeBankedResetReminders() }
    }
    @Published var gemini: ProviderSnapshot = .loading(.gemini)
    @Published var zai: ProviderSnapshot = .loading(.zai)
    @Published var muse: ProviderSnapshot = .loading(.muse)
    @Published var alicloud: ProviderSnapshot = .loading(.alicloud)
    @Published var commandCode: ProviderSnapshot = .loading(.commandCode)

    let historyStore: UsageHistoryStore
    @Published private(set) var historyError: String?
    @Published private(set) var historyRevision = 0

    @Published var lastUpdated: Date?
    @Published var lastUpdatedByProvider: [ProviderKind: Date] = [:]
    @Published var refreshingProviders: Set<ProviderKind> = []
    @Published var autoRefreshInterval: AutoRefreshInterval

    @Published private(set) var launchAtStartupState: LaunchAtStartupState
    @Published private(set) var launchAtStartupErrorMessage: String?

    private let claudeProbe: any ProviderSnapshotFetching
    private let codexProbe: any ProviderSnapshotFetching
    private let geminiProbe: any ProviderSnapshotFetching
    private let zaiProbe: any ProviderSnapshotFetching
    private let museProbe: any ProviderSnapshotFetching
    private let alicloudProbe: any ProviderSnapshotFetching
    private let commandCodeProbe: any ProviderSnapshotFetching
    private let launchAtStartupManager: any LaunchAtStartupManaging
    private let userDefaults: UserDefaults

    private var refreshLoopTask: Task<Void, Never>?
    private var fullRefreshTask: Task<Void, Never>?
    private var providerRefreshTasks: [ProviderKind: Task<Void, Never>] = [:]
    private var preservedFailureCounts: [ProviderKind: Int] = [:]

    init(
        claudeProbe: any ProviderSnapshotFetching,
        codexProbe: any ProviderSnapshotFetching,
        geminiProbe: any ProviderSnapshotFetching = MissingGeminiSnapshotFetcher(),
        zaiProbe: any ProviderSnapshotFetching = MissingZaiSnapshotFetcher(),
        museProbe: any ProviderSnapshotFetching = MissingMuseSnapshotFetcher(),
        alicloudProbe: any ProviderSnapshotFetching = MissingAliCloudSnapshotFetcher(),
        commandCodeProbe: any ProviderSnapshotFetching = MissingCommandCodeSnapshotFetcher(),
        launchAtStartupManager: any LaunchAtStartupManaging = LaunchAtStartupManager(),
        userDefaults: UserDefaults = .standard,
        startRefreshLoop: Bool = true,
        resetAppliers: [ProviderKind: any BankedResetApplying] = [:],
        notificationScheduler: (any BankedResetNotificationScheduling)? = nil,
        historyStore: UsageHistoryStore = UsageHistoryStore()
    ) {
        self.historyStore = historyStore
        self.bankedResetReminders = BankedResetReminderCoordinator(
            scheduler: notificationScheduler ?? makeBankedResetNotificationScheduler(), userDefaults: userDefaults)
        self.resetAppliers = resetAppliers
        self.runsAutoApplyLoop = startRefreshLoop
        self.bankedResetAutoApplyEnabled = userDefaults.bool(forKey: Self.bankedResetAutoApplyEnabledKey)
        self.bankedResetAutoApplyLeadMinutes = min(60, max(1,
            userDefaults.object(forKey: Self.bankedResetAutoApplyLeadMinutesKey) as? Int ?? 5))
        self.claudeProbe = claudeProbe
        self.codexProbe = codexProbe
        self.geminiProbe = geminiProbe
        self.zaiProbe = zaiProbe
        self.museProbe = museProbe
        self.alicloudProbe = alicloudProbe
        self.commandCodeProbe = commandCodeProbe
        self.launchAtStartupManager = launchAtStartupManager
        self.userDefaults = userDefaults

        let storedRawValue = userDefaults.object(forKey: Self.autoRefreshIntervalKey) as? Int
        self.autoRefreshInterval = storedRawValue.flatMap(AutoRefreshInterval.init(rawValue:))
            ?? .defaultValue
        self.launchAtStartupState = launchAtStartupManager.currentState()
        self.launchAtStartupErrorMessage = nil

        if startRefreshLoop {
            restartRefreshLoop()
            restartAutoApplyLoop()
        }
    }

    convenience init() {
        self.init(
            claudeProbe: ClaudeProbe(),
            codexProbe: CodexProbe(),
            geminiProbe: GeminiProbe(),
            zaiProbe: ZaiProbe(),
            museProbe: MuseProbe(),
            alicloudProbe: AliCloudProbe(),
            commandCodeProbe: CommandCodeProbe(),
            resetAppliers: [
                .claude: ClaudeBankedResetApplier(probe: ClaudeProbe(), transport: ClaudeLiveResetTransport()),
                .codex: CodexBankedResetApplier(transport: CodexLiveResetTransport())
            ],
            historyStore: .live()
        )
    }

    deinit {
        refreshLoopTask?.cancel()
        autoApplyLoopTask?.cancel()
    }

    var visibleSnapshots: [ProviderSnapshot] {
        providerSnapshots.filter {
            agentStatus(for: $0.provider).availability.showsInPopover
        }
    }

    var hasVisibleSnapshots: Bool {
        !visibleSnapshots.isEmpty
    }

    var isRefreshing: Bool {
        !refreshingProviders.isEmpty
    }

    func refresh() async {
        if let fullRefreshTask {
            await fullRefreshTask.value
            return
        }
        let task = Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                for provider in ProviderKind.allCases {
                    group.addTask {
                        await self.refresh(provider)
                    }
                }
            }
        }
        fullRefreshTask = task
        await task.value
        fullRefreshTask = nil
    }

    func refresh(_ provider: ProviderKind) async {
        if let task = providerRefreshTasks[provider] {
            await task.value
            return
        }
        refreshingProviders.insert(provider)
        let task = Task { @MainActor in
            let previous = snapshot(for: provider)
            let current = await probe(for: provider).fetch()
            let readingTime = Date.now
            if hasUsageData(in: current) {
                do {
                    try await historyStore.record(current, at: readingTime)
                    historyError = nil
                } catch { historyError = error.localizedDescription }
            }
            let merged = merge(previous: previous, current: current, provider: provider)
            setSnapshot(merged, for: provider)
            let prefix = provider.routeKey + ":"
            bankedResetMessages = bankedResetMessages.filter { !$0.key.hasPrefix(prefix) }
            bankedResetResultRows = bankedResetResultRows.filter { !$0.key.hasPrefix(prefix) }
            if hasUsageData(in: current) {
                var keys = userDefaults.dictionary(forKey: Self.resetKeysKey) as? [String: String] ?? [:]
                let listed = Set(current.bankedResets.map { Self.resetKey(provider: provider, id: $0.id) })
                keys = keys.filter { !$0.key.hasPrefix(prefix) || listed.contains($0.key) }
                userDefaults.set(keys, forKey: Self.resetKeysKey)
            }

            let now = Date.now
            lastUpdatedByProvider[provider] = now
            lastUpdated = now
            historyRevision += 1
            refreshingProviders.remove(provider)
        }
        providerRefreshTasks[provider] = task
        await task.value
        providerRefreshTasks[provider] = nil
    }

    func history(range: UsageHistoryRange = .week, provider: ProviderKind? = nil) async -> UsageHistoryResponse {
        do {
            let response = try await historyStore.history(range: range, provider: provider)
            historyError = nil
            return response
        } catch {
            historyError = error.localizedDescription
            return UsageHistory.response(series: [], range: range, provider: provider)
        }
    }

    func historyProviders() async -> [ProviderKind] {
        let stored = (try? await historyStore.providers()) ?? []
        return ProviderKind.allCases.filter { stored.contains($0.routeKey) }
    }

    func synchronizeBankedResetReminders() {
        bankedResetReminders.snapshots = [claude, codex]
        bankedResetReminders.autoApplyEnabled = bankedResetAutoApplyEnabled
        bankedResetReminders.leadMinutes = bankedResetAutoApplyLeadMinutes
        bankedResetReminders.language = AppLanguage(rawValue: userDefaults.string(forKey: "appLanguage") ?? "en") ?? .english
        Task { await bankedResetReminders.synchronize() }
    }

    static func resetKey(provider: ProviderKind, id: String) -> String { provider.routeKey + ":" + id }

    func applyBankedReset(provider: ProviderKind, id: String) async -> BankedResetApplyResult {
        let key = Self.resetKey(provider: provider, id: id)
        if let task = resetTasks[key] { return await task.value }
        let current = snapshot(for: provider)
        guard let reset = current.bankedResets.first(where: { $0.id == id }) else {
            let message = BankedResetOutcome.notFound.message(provider: provider)
            bankedResetMessages[key] = message
            return .init(provider: provider, resetID: id, outcome: .notFound, message: message, usage: current)
        }
        guard reset.usable else {
            let message = BankedResetOutcome.notUsable.message(provider: provider, detail: reset.note)
            bankedResetMessages[key] = message
            return .init(provider: provider, resetID: id, outcome: .notUsable, message: message, usage: current)
        }
        var keys = userDefaults.dictionary(forKey: Self.resetKeysKey) as? [String: String] ?? [:]
        let requestKey = keys[key] ?? UUID().uuidString
        keys[key] = requestKey
        userDefaults.set(keys, forKey: Self.resetKeysKey)
        applyingBankedResets.insert(key)
        let task = Task { @MainActor in
            let upstream = await (resetAppliers[provider] ?? UnavailableBankedResetApplier()).apply(id: id, idempotencyKey: requestKey)
            await refresh(provider)
            let message = upstream.outcome.message(provider: provider, detail: upstream.detail)
            bankedResetMessages[key] = message
            if !snapshot(for: provider).bankedResets.contains(where: { $0.id == id }) {
                var row = reset
                row.usable = false
                row.status = upstream.outcome.applied ? "redeemed" : "unavailable"
                bankedResetResultRows[key] = row
            }
            if upstream.outcome.applied { resetCompleted.insert(key) }
            return BankedResetApplyResult(provider: provider, resetID: id, outcome: upstream.outcome,
                                         message: message, usage: snapshot(for: provider))
        }
        resetTasks[key] = task
        let result = await task.value
        resetTasks[key] = nil
        applyingBankedResets.remove(key)
        return result
    }

    func autoApplyTick(now fixedNow: Date? = nil) async {
        let now = fixedNow ?? .now
        guard bankedResetAutoApplyEnabled, !autoApplyTickRunning else { return }
        autoApplyTickRunning = true
        defer { autoApplyTickRunning = false }
        let due = [ProviderKind.claude, .codex].flatMap { provider in
            snapshot(for: provider).bankedResets.map { (provider, $0) }
        }.filter { provider, reset in
            let key = Self.resetKey(provider: provider, id: reset.id)
            return BankedResetAutoApplyPolicy.isDue(reset, now: now, leadMinutes: bankedResetAutoApplyLeadMinutes,
                                                   completed: resetCompleted.contains(key), lastAttempt: resetAttempts[key])
        }.sorted { $0.1.expiresAt! < $1.1.expiresAt! }
        for (provider, reset) in due {
            guard bankedResetAutoApplyEnabled, !Task.isCancelled else { return }
            let key = Self.resetKey(provider: provider, id: reset.id)
            let attemptNow = fixedNow ?? .now
            guard BankedResetAutoApplyPolicy.isDue(reset, now: attemptNow, leadMinutes: bankedResetAutoApplyLeadMinutes,
                completed: resetCompleted.contains(key), lastAttempt: resetAttempts[key]) else { continue }
            resetAttempts[key] = attemptNow
            await refresh(provider)
            let recheckNow = fixedNow ?? .now
            guard bankedResetAutoApplyEnabled, !Task.isCancelled,
                  let fresh = snapshot(for: provider).bankedResets.first(where: { $0.id == reset.id }),
                  BankedResetAutoApplyPolicy.isDue(fresh, now: recheckNow, leadMinutes: bankedResetAutoApplyLeadMinutes,
                                                  completed: resetCompleted.contains(key)) else { continue }
            let result = await applyBankedReset(provider: provider, id: fresh.id)
            lastAutoApplyResult = .init(provider: provider, title: fresh.title, message: result.message, date: now)
        }
    }

    private func restartAutoApplyLoop() {
        autoApplyLoopTask?.cancel()
        guard bankedResetAutoApplyEnabled, runsAutoApplyLoop else { return }
        autoApplyLoopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.autoApplyTick()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    func setAutoRefreshInterval(_ interval: AutoRefreshInterval) {
        guard interval != autoRefreshInterval else { return }

        autoRefreshInterval = interval
        userDefaults.set(interval.rawValue, forKey: Self.autoRefreshIntervalKey)
        restartRefreshLoop()
    }

    var launchAtStartupEnabled: Bool {
        switch launchAtStartupState {
        case .enabled, .requiresApproval:
            true
        case .disabled, .unsupported:
            false
        }
    }

    var launchAtStartupNeedsApproval: Bool {
        launchAtStartupState == .requiresApproval
    }

    var launchAtStartupSupported: Bool {
        launchAtStartupState != .unsupported
    }

    func setLaunchAtStartupEnabled(_ enabled: Bool) {
        do {
            launchAtStartupState = try launchAtStartupManager.setEnabled(enabled)
            launchAtStartupErrorMessage = nil
        } catch {
            launchAtStartupState = launchAtStartupManager.currentState()
            launchAtStartupErrorMessage = error.localizedDescription
        }
    }

    func agentStatus(for provider: ProviderKind) -> AgentStatus {
        let snapshot = snapshot(for: provider)

        if hasUsageData(in: snapshot) {
            return AgentStatus(provider: provider, availability: .available, message: nil)
        }

        guard let message = message(in: snapshot) else {
            return AgentStatus(provider: provider, availability: .loading, message: nil)
        }

        if message == "Loading…" {
            return AgentStatus(provider: provider, availability: .loading, message: nil)
        }

        let lowercasedMessage = message.lowercased()
        let availability: AgentAvailability

        switch provider {
        case .claude, .gemini, .muse, .alicloud, .commandCode:
            if lowercasedMessage.contains("credentials not found") ||
                lowercasedMessage.contains("credentials could not be read") {
                availability = .missingAuth
            } else if lowercasedMessage.contains("keychain access denied") {
                availability = .accessDenied
            } else if lowercasedMessage.contains("session expired") ||
                        lowercasedMessage.contains("authentication failed") {
                availability = .sessionExpired
            } else {
                availability = .error(message)
            }
        case .codex:
            if lowercasedMessage.contains("not installed or not on path") {
                availability = .notInstalled
            } else if lowercasedMessage.contains("not logged in") ||
                        lowercasedMessage.contains("please log in") {
                availability = .notLoggedIn
            } else {
                availability = .error(message)
            }
        case .zai:
            if lowercasedMessage.contains("api key not found") {
                availability = .missingAuth
            } else if lowercasedMessage.contains("authentication failed") {
                availability = .notLoggedIn
            } else {
                availability = .error(message)
            }
        }

        return AgentStatus(provider: provider, availability: availability, message: message)
    }

    private var providerSnapshots: [ProviderSnapshot] {
        [claude, codex, gemini, zai, muse, alicloud, commandCode]
    }

    func snapshot(for provider: ProviderKind) -> ProviderSnapshot {
        switch provider {
        case .claude:
            claude
        case .codex:
            codex
        case .gemini:
            gemini
        case .zai:
            zai
        case .muse:
            muse
        case .alicloud:
            alicloud
        case .commandCode:
            commandCode
        }
    }

    private func setSnapshot(_ snapshot: ProviderSnapshot, for provider: ProviderKind) {
        switch provider {
        case .claude:
            claude = snapshot
        case .codex:
            codex = snapshot
        case .gemini:
            gemini = snapshot
        case .zai:
            zai = snapshot
        case .muse:
            muse = snapshot
        case .alicloud:
            alicloud = snapshot
        case .commandCode:
            commandCode = snapshot
        }
    }

    private func probe(for provider: ProviderKind) -> any ProviderSnapshotFetching {
        switch provider {
        case .claude:
            claudeProbe
        case .codex:
            codexProbe
        case .gemini:
            geminiProbe
        case .zai:
            zaiProbe
        case .muse:
            museProbe
        case .alicloud:
            alicloudProbe
        case .commandCode:
            commandCodeProbe
        }
    }

    private func restartRefreshLoop() {
        refreshLoopTask?.cancel()

        let interval = autoRefreshInterval
        refreshLoopTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }

            await self?.refresh()
            guard !Task.isCancelled, interval != .manual else { return }

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval.duration))
                } catch {
                    return
                }

                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    private func hasUsageData(in snapshot: ProviderSnapshot) -> Bool {
        snapshot.fiveHour.usedPercentage != nil ||
            snapshot.weekly.usedPercentage != nil ||
            snapshot.modelWindows.contains { $0.window.usedPercentage != nil }
    }

    private func message(in snapshot: ProviderSnapshot) -> String? {
        snapshot.fiveHour.message ?? snapshot.weekly.message
    }

    private func merge(
        previous: ProviderSnapshot,
        current: ProviderSnapshot,
        provider: ProviderKind
    ) -> ProviderSnapshot {
        if hasUsageData(in: current) {
            preservedFailureCounts[provider] = 0
            return current
        }

        guard hasUsageData(in: previous) else {
            preservedFailureCounts[provider] = 0
            var failed = current
            failed.bankedResets = previous.bankedResets
            return failed
        }

        let lowercasedMessage = message(in: current)?.lowercased() ?? ""
        if lowercasedMessage.contains("http 429") ||
            lowercasedMessage.contains("too many requests") ||
            lowercasedMessage.contains("rate limit exceeded") ||
            lowercasedMessage.contains("rate_limit_exceeded") {
            preservedFailureCounts[provider, default: 0] += 1
            return previous
        }

        let preservedCount = preservedFailureCounts[provider, default: 0]
        if provider == .claude && preservedCount == 0 {
            let transientAuthenticationMessages = [
                "credentials not found",
                "credentials could not be read",
                "authentication failed",
                "session expired"
            ]

            if transientAuthenticationMessages.contains(where: lowercasedMessage.contains) {
                preservedFailureCounts[provider] = preservedCount + 1
                return previous
            }
        }

        preservedFailureCounts[provider] = 0
        var failed = current
        failed.bankedResets = previous.bankedResets
        return failed
    }
}
