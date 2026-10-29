import Foundation

public struct ResetNotice: Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let fireAt: Date

    public init(id: String, title: String, body: String, fireAt: Date) {
        self.id = id
        self.title = title
        self.body = body
        self.fireAt = fireAt
    }
}

public struct ResetNotificationLedger: Codable, Equatable, Sendable {
    public private(set) var issuedIDs: [String] = []
    public init() {}

    public mutating func record(_ identifier: String) {
        guard !issuedIDs.contains(identifier) else { return }
        issuedIDs.append(identifier)
        if issuedIDs.count > 512 { issuedIDs.removeFirst(issuedIDs.count - 512) }
    }

    public mutating func forget(_ identifiers: Set<String>) {
        issuedIDs.removeAll { identifiers.contains($0) }
    }
}

/// Produces deduplicated announcements and reminders without treating a deadline as execution.
public struct ResetNotificationPlan: Sendable {
    public static let prefix = "tokenwatch.reset."
    public let notices: [ResetNotice]
    public let activeIDs: Set<String>

    public static func make(tracker: ResetTracker, ledger: ResetNotificationLedger, now: Date) -> Self {
        var notices: [ResetNotice] = []
        var activeIDs: Set<String> = []
        func add(_ id: String, title: String, body: String, at: Date) {
            activeIDs.insert(id)
            if !ledger.issuedIDs.contains(id) {
                notices.append(ResetNotice(id: id, title: title, body: body, fireAt: at))
            }
        }
        for event in tracker.pending.sorted(by: { ($0.announcedAt, $0.id) < ($1.announcedAt, $1.id) }).prefix(16) where event.kind == .regular {
            let body: String
            if let expected = event.scheduledFor {
                body = expected > now
                    ? "Expected by \(expected.formatted(date: .abbreviated, time: .shortened)). Timing may change."
                    : "An announced reset is still awaiting confirmation."
            } else {
                body = "A reset was announced. No time has been confirmed."
            }
            add(prefix + "announced." + event.id, title: "Codex reset announced", body: body, at: now.addingTimeInterval(1))
            if let expected = event.scheduledFor {
                let reminder = expected.addingTimeInterval(-900)
                if reminder > now.addingTimeInterval(1) {
                    let id = prefix + "reminder." + event.id + "." + String(Int(expected.timeIntervalSince1970))
                    add(id, title: "Codex reset expected soon",
                        body: "The announced reset is expected in about 15 minutes. Check Token Watch for confirmation.", at: reminder)
                }
            }
        }
        if let latest = tracker.latest, latest.kind == .regular,
           latest.announcedAt <= now, latest.announcedAt >= now.addingTimeInterval(-3600) {
            add(prefix + "confirmed." + latest.id, title: "Codex reset reported",
                body: "Codex Resets reports a reset. Refresh your Mac’s readings to check your allowance.", at: now.addingTimeInterval(1))
        }
        return Self(notices: notices, activeIDs: activeIDs)
    }
}
