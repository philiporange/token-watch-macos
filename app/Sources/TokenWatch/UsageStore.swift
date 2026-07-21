import Foundation
import SwiftUI

protocol ProviderSnapshotFetching: Sendable {
    func fetch() async -> ProviderSnapshot
}

extension ClaudeProbe: ProviderSnapshotFetching {}
extension CodexProbe: ProviderSnapshotFetching {}
extension GeminiProbe: ProviderSnapshotFetching {}
extension ZaiProbe: ProviderSnapshotFetching {}

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

@MainActor
final class UsageStore: ObservableObject {
    private static let autoRefreshIntervalKey = "autoRefreshInterval"

    @Published var claude: ProviderSnapshot = .loading(.claude)
    @Published var codex: ProviderSnapshot = .loading(.codex)
    @Published var gemini: ProviderSnapshot = .loading(.gemini)
    @Published var zai: ProviderSnapshot = .loading(.zai)

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
    private let launchAtStartupManager: any LaunchAtStartupManaging
    private let userDefaults: UserDefaults

    private var refreshLoopTask: Task<Void, Never>?
    private var preservedFailureCounts: [ProviderKind: Int] = [:]

    init(
        claudeProbe: any ProviderSnapshotFetching,
        codexProbe: any ProviderSnapshotFetching,
        geminiProbe: any ProviderSnapshotFetching = MissingGeminiSnapshotFetcher(),
        zaiProbe: any ProviderSnapshotFetching = MissingZaiSnapshotFetcher(),
        launchAtStartupManager: any LaunchAtStartupManaging = LaunchAtStartupManager(),
        userDefaults: UserDefaults = .standard,
        startRefreshLoop: Bool = true
    ) {
        self.claudeProbe = claudeProbe
        self.codexProbe = codexProbe
        self.geminiProbe = geminiProbe
        self.zaiProbe = zaiProbe
        self.launchAtStartupManager = launchAtStartupManager
        self.userDefaults = userDefaults

        let storedRawValue = userDefaults.object(forKey: Self.autoRefreshIntervalKey) as? Int
        self.autoRefreshInterval = storedRawValue.flatMap(AutoRefreshInterval.init(rawValue:))
            ?? .defaultValue
        self.launchAtStartupState = launchAtStartupManager.currentState()
        self.launchAtStartupErrorMessage = nil

        if startRefreshLoop {
            restartRefreshLoop()
        }
    }

    convenience init() {
        self.init(
            claudeProbe: ClaudeProbe(),
            codexProbe: CodexProbe(),
            geminiProbe: GeminiProbe(),
            zaiProbe: ZaiProbe()
        )
    }

    deinit {
        refreshLoopTask?.cancel()
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
        await withTaskGroup(of: Void.self) { group in
            for provider in ProviderKind.allCases {
                group.addTask {
                    await self.refresh(provider)
                }
            }
        }
    }

    func refresh(_ provider: ProviderKind) async {
        guard !refreshingProviders.contains(provider) else { return }

        refreshingProviders.insert(provider)
        defer {
            refreshingProviders.remove(provider)
        }

        let previous = snapshot(for: provider)
        let current = await probe(for: provider).fetch()
        let merged = merge(previous: previous, current: current, provider: provider)
        setSnapshot(merged, for: provider)

        let now = Date.now
        lastUpdatedByProvider[provider] = now
        lastUpdated = now
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
        case .claude, .gemini:
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
        [claude, codex, gemini, zai]
    }

    private func snapshot(for provider: ProviderKind) -> ProviderSnapshot {
        switch provider {
        case .claude:
            claude
        case .codex:
            codex
        case .gemini:
            gemini
        case .zai:
            zai
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
            return current
        }

        let lowercasedMessage = message(in: current)?.lowercased() ?? ""
        if lowercasedMessage.contains("http 429") ||
            lowercasedMessage.contains("rate limit") {
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
        return current
    }
}
