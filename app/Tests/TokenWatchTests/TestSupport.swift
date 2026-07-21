import Foundation
@testable import TokenWatch

// MARK: - Snapshot / window builders

func makeWindow(
    _ kind: UsageWindowKind,
    used: Double? = nil,
    resetsAt: Date? = nil,
    message: String? = nil
) -> UsageWindow {
    UsageWindow(kind: kind, usedPercentage: used, resetsAt: resetsAt, message: message)
}

func makeSnapshot(
    _ provider: ProviderKind,
    fiveHourUsed: Double? = nil,
    weeklyUsed: Double? = nil,
    fiveHourReset: Date? = nil,
    weeklyReset: Date? = nil,
    fiveHourMessage: String? = nil,
    weeklyMessage: String? = nil,
    modelWindows: [ModelUsageWindow] = [],
    detail: String? = nil
) -> ProviderSnapshot {
    ProviderSnapshot(
        provider: provider,
        fiveHour: UsageWindow(
            kind: .fiveHour,
            usedPercentage: fiveHourUsed,
            resetsAt: fiveHourReset,
            message: fiveHourMessage
        ),
        weekly: UsageWindow(
            kind: .weekly,
            usedPercentage: weeklyUsed,
            resetsAt: weeklyReset,
            message: weeklyMessage
        ),
        modelWindows: modelWindows,
        detail: detail
    )
}

// MARK: - Temp directory

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Probe test doubles

/// FIFO queue of snapshots. The last element repeats forever once the queue is drained.
actor ProbeQueue {
    private var items: [ProviderSnapshot]

    init(_ items: [ProviderSnapshot]) {
        precondition(!items.isEmpty, "ProbeQueue requires at least one snapshot")
        self.items = items
    }

    func next() -> ProviderSnapshot {
        if items.count == 1 { return items[0] }
        return items.removeFirst()
    }
}

struct ProbeStub: ProviderSnapshotFetching {
    let queue: ProbeQueue
    func fetch() async -> ProviderSnapshot { await queue.next() }
}

actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

struct CountingProbe: ProviderSnapshotFetching {
    let snapshot: ProviderSnapshot
    let counter: CallCounter
    func fetch() async -> ProviderSnapshot {
        await counter.increment()
        return snapshot
    }
}

// MARK: - Polling helper

@discardableResult
func waitUntil(
    maxAttempts: Int = 100,
    pollInterval: Duration = .milliseconds(20),
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<maxAttempts {
        if await condition() { return true }
        try? await Task.sleep(for: pollInterval)
    }
    return await condition()
}

// MARK: - Launch-at-startup spy

@MainActor
final class LaunchAtStartupManagerSpy: LaunchAtStartupManaging {
    var state: LaunchAtStartupState = .disabled
    var failure: Error?
    private(set) var setEnabledCalls: [Bool] = []

    func currentState() -> LaunchAtStartupState { state }

    func setEnabled(_ enabled: Bool) throws -> LaunchAtStartupState {
        setEnabledCalls.append(enabled)
        if let failure { throw failure }
        state = enabled ? .enabled : .disabled
        return state
    }
}
