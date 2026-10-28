import Foundation

/// Keeps foreground connection retries quick while limiting repeated requests on an unreachable network.
public struct ConnectionRetrySchedule: Equatable, Sendable {
    public private(set) var failures = 0

    public init() {}

    public var nextDelay: TimeInterval {
        guard failures > 0 else { return 60 }
        return [5.0, 10.0, 20.0, 30.0][min(failures - 1, 3)]
    }

    public mutating func recordFailure() {
        failures = min(failures + 1, 4)
    }

    public mutating func recordSuccess() {
        failures = 0
    }
}
