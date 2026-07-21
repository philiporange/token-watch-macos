import Foundation

public enum StatusItemRepairReason: String, Sendable {
    case launch = "launch"
    case wake = "wake"
    case wakeFollowup = "wake-followup"
    case displayChange = "display-change"
}

@MainActor
public final class StatusItemRepairDebouncer {
    private let delay: Duration
    private let repair: @MainActor (StatusItemRepairReason) -> Void
    private var task: Task<Void, Never>?

    public init(
        delay: Duration = .milliseconds(500),
        repair: @escaping @MainActor (StatusItemRepairReason) -> Void
    ) {
        self.delay = delay
        self.repair = repair
    }

    public func schedule(reason: StatusItemRepairReason) {
        cancel()
        let delay = self.delay
        let repair = self.repair
        task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
                guard !Task.isCancelled, self != nil else { return }
                repair(reason)
            } catch {
                // Task was cancelled
            }
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}
