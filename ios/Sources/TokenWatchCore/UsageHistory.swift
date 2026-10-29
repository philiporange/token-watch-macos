import Foundation

public enum UsageHistoryRange: String, Codable, CaseIterable, Identifiable, Sendable {
    case day = "24h", week = "7d", month = "30d", quarter = "90d", year = "365d", all

    public var id: String { rawValue }
    public var label: String { self == .year ? "1y" : self == .all ? "All" : rawValue }
    public var duration: TimeInterval? {
        switch self {
        case .day: 86400
        case .week: 7 * 86400
        case .month: 30 * 86400
        case .quarter: 90 * 86400
        case .year: 365 * 86400
        case .all: nil
        }
    }

    public func xDomain(now: Date, firstPoint: Date? = nil) -> ClosedRange<Date> {
        let start = duration.map { now.addingTimeInterval(-$0) } ?? min(firstPoint ?? now, now)
        // A fresh, single-point all-time history still needs a nonzero chart domain.
        let span = max(now.timeIntervalSince(start), 1)
        return start...now.addingTimeInterval(span * 0.25)
    }
}

public struct UsageHistoryPoint: Codable, Equatable, Sendable {
    public let t: Date
    public let used: Double
    public let resetsAt: Date?

    public init(t: Date, used: Double, resetsAt: Date? = nil) {
        self.t = t
        self.used = used
        self.resetsAt = resetsAt
    }

    enum CodingKeys: String, CodingKey { case t, used, resetsAt = "resets_at" }
}

public struct UsageHistoryProjection: Codable, Equatable, Sendable {
    public let method: String
    public let ratePerHour: Double
    public let atReset: Double
    public let limitAt: Date?
    public let from: UsageHistoryPoint
    public let to: UsageHistoryPoint

    enum CodingKeys: String, CodingKey {
        case method, from, to, ratePerHour = "rate_per_hour", atReset = "at_reset", limitAt = "limit_at"
    }

    /// Returns a projection segment with its endpoint interpolated at the visible domain end.
    public func clipped(to domainEnd: Date) -> [UsageHistoryPoint] {
        guard from.t <= domainEnd else { return [] }
        guard to.t > domainEnd, to.t > from.t else { return [from, to] }
        let fraction = domainEnd.timeIntervalSince(from.t) / to.t.timeIntervalSince(from.t)
        return [from, .init(t: domainEnd, used: from.used + (to.used - from.used) * fraction)]
    }

    public func label(kind: String) -> String {
        guard method == "trend" else { return "Average pace" }
        switch kind {
        case "5h": return "1 h trend"
        case "Month": return "3 d trend"
        default: return "24 h trend"
        }
    }

    public func summary(kind: String, reset: Date?, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE d MMM HH:mm"
        let rate = ratePerHour.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).precision(.fractionLength(0...2)))
        let prefix = "\(label(kind: kind)) \(rate)%/h · "
        if let limitAt { return prefix + "reaches 100% " + formatter.string(from: limitAt) }
        let percentage = atReset.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).precision(.fractionLength(0...2)))
        return prefix + "\(percentage)% at reset " + formatter.string(from: reset ?? to.t)
    }
}

public struct UsageHistorySeries: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let provider: String
    public let providerName: String
    public let window: String
    public let label: String
    public let kind: String
    public let points: [UsageHistoryPoint]
    public let current: UsageHistoryPoint
    public let projections: [UsageHistoryProjection]

    enum CodingKeys: String, CodingKey {
        case id, provider, window, label, kind, points, current, projections, providerName = "provider_name"
    }

    public var plottedLine: [UsageHistoryPoint] {
        guard let last = points.last else { return [current] }
        return current.t > last.t ? points + [current] : points
    }

    public var noProjectionReason: String {
        current.resetsAt == nil ? "No reset time" : "Not enough history yet"
    }
}

public struct UsageHistory: Codable, Equatable, Sendable {
    public struct Rules: Codable, Equatable, Sendable {
        public let intervalMinutes: Int
        public let changePoints: Double
        enum CodingKeys: String, CodingKey { case intervalMinutes = "interval_minutes", changePoints = "change_points" }
    }

    public let generatedAt: Date
    public let range: UsageHistoryRange
    public let since: Date?
    public let rules: Rules
    public let series: [UsageHistorySeries]

    enum CodingKeys: String, CodingKey { case generatedAt = "generated_at", range, since, rules, series }

    public static func decode(_ data: Data) throws -> Self {
        try UsageSnapshot.makeDecoder().decode(Self.self, from: data)
    }

    public func xDomain(now: Date) -> ClosedRange<Date> {
        if let since {
            return since...max(since.addingTimeInterval(1), now.addingTimeInterval(max(0, now.timeIntervalSince(since)) * 0.25))
        }
        let first = series.flatMap(\.plottedLine).map(\.t).min()
        return range.xDomain(now: now, firstPoint: first)
    }
}
