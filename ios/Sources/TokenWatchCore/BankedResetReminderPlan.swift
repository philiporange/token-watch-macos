import Foundation

/// Plans local reminders for the eight soonest expiring account reset credits.
public enum BankedResetReminderPlan {
    public static let prefix = "tokenwatch.banked."

    public static func make(providers: [ProviderUsage], autoApply: BankedResetAutoApply?, now: Date)
        -> (notices: [ResetNotice], activeIDs: Set<String>) {
        let candidates = providers.flatMap { provider in
            provider.bankedResets.compactMap { reset -> (ProviderUsage, BankedReset, Date)? in
                guard let expiry = reset.expiresAt, expiry > now,
                      !["expired", "redeemed", "redeeming"].contains(reset.status) else { return nil }
                return (provider, reset, expiry)
            }
        }.sorted {
            if $0.2 != $1.2 { return $0.2 < $1.2 }
            return ($0.0.provider, $0.1.id) < ($1.0.provider, $1.1.id)
        }.prefix(8)
        let offsets = [(1440, "24 hours"), (720, "12 hours"), (240, "4 hours"), (60, "1 hour"), (15, "15 minutes")]
        var notices: [ResetNotice] = []
        for (provider, reset, expiry) in candidates {
            var body = "“\(reset.title)” expires \(expiry.formatted(date: .abbreviated, time: .shortened))."
            if reset.usable, let autoApply, autoApply.enabled {
                body += " Your Mac will apply it automatically \(autoApply.leadMinutes) minutes before it expires."
            } else if reset.usable {
                body += " Apply it in Token Watch before then."
            } else if let note = reset.note {
                body += " " + note
            }
            for (minutes, label) in offsets {
                let fireAt = expiry.addingTimeInterval(-Double(minutes) * 60)
                guard fireAt > now.addingTimeInterval(1) else { continue }
                let id = prefix + MacConnection.routeKey(for: provider.provider) + "." + reset.id
                    + ".\(minutes).\(Int(expiry.timeIntervalSince1970))"
                notices.append(ResetNotice(id: id, title: "\(provider.provider) reset expires in \(label)",
                                           body: body, fireAt: fireAt))
            }
        }
        return (notices, Set(notices.map(\.id)))
    }
}
