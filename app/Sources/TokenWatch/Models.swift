import Foundation

// MARK: - Provider Kind

enum ProviderKind: String, CaseIterable {
    case claude = "Claude"
    case codex = "Codex"
    case gemini = "Gemini"
    case zai = "Z.ai"
    case muse = "Muse"
    case alicloud = "AliCloud"
    case commandCode = "Command Code"
}

// MARK: - Provider Display Name

enum ProviderDisplayName {
    static func displayName(for provider: ProviderKind) -> String {
        switch provider {
        case .claude: return "Cl"
        case .codex: return "Cx"
        case .gemini: return "Gm"
        case .zai: return "Z"
        case .muse: return "Mu"
        case .alicloud: return "Ali"
        case .commandCode: return "Cc"
        }
    }
}

// MARK: - Usage Window Kind

enum UsageWindowKind: String {
    case fiveHour = "5h"
    case weekly = "Week"
    case modelWeekly = "Model"
    case monthly = "Month"

    var isWeekly: Bool {
        self == .weekly || self == .modelWeekly
    }

    var supportsPacing: Bool {
        isWeekly || self == .monthly
    }

    var pacingWindowDuration: TimeInterval? {
        switch self {
        case .weekly, .modelWeekly:
            return 7 * 24 * 60 * 60 // 7 days in seconds
        case .monthly:
            return 30 * 24 * 60 * 60 // 30 days in seconds
        case .fiveHour:
            return nil
        }
    }
}

// MARK: - Usage Window

struct UsageWindow: Identifiable {
    let kind: UsageWindowKind
    var usedPercentage: Double?
    var resetsAt: Date?
    var message: String?

    var id: String {
        kind.rawValue
    }

    static func placeholder(_ kind: UsageWindowKind, message: String = "Loading…") -> UsageWindow {
        UsageWindow(kind: kind, usedPercentage: nil, resetsAt: nil, message: message)
    }
}

// MARK: - Model Usage Window

struct ModelUsageWindow: Identifiable {
    let modelName: String
    var window: UsageWindow
    var isActive: Bool

    var id: String {
        modelName.lowercased()
    }
}

// MARK: - Provider Snapshot

struct ProviderSnapshot {
    let provider: ProviderKind
    var fiveHour: UsageWindow
    var weekly: UsageWindow
    var modelWindows: [ModelUsageWindow] = []
    var detail: String?
    var bankedResets: [BankedReset] = []

    var showsLongWindow: Bool {
        !(provider == .zai && weekly.kind == .monthly)
    }

    var pacingWindow: UsageWindow {
        guard showsLongWindow else {
            return fiveHour
        }
        let candidates = [weekly] + modelWindows.filter { $0.window.kind.supportsPacing }.map { $0.window }
        let sorted = candidates.sorted { a, b in
            let aPct = a.usedPercentage ?? -1
            let bPct = b.usedPercentage ?? -1
            return aPct > bPct
        }
        return sorted.first ?? weekly
    }

    static func loading(_ provider: ProviderKind) -> ProviderSnapshot {
        let weeklyKind: UsageWindowKind = provider == .zai ? .monthly : .weekly
        return ProviderSnapshot(
            provider: provider,
            fiveHour: .placeholder(.fiveHour),
            weekly: .placeholder(weeklyKind),
            modelWindows: [],
            detail: nil
        )
    }
}

// MARK: - Agent Availability

enum AgentAvailability: Equatable {
    case loading
    case available
    case missingAuth
    case accessDenied
    case sessionExpired
    case notInstalled
    case notLoggedIn
    case error(String)

    var showsInPopover: Bool {
        switch self {
        case .loading, .available:
            return true
        default:
            return false
        }
    }
}

// MARK: - Agent Status

struct AgentStatus: Equatable {
    let provider: ProviderKind
    let availability: AgentAvailability
    let message: String?
}

// MARK: - Auto Refresh Interval

enum AutoRefreshInterval: Int, CaseIterable, Identifiable {
    case manual = 0
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300
    case tenMinutes = 600
    case fifteenMinutes = 900
    case thirtyMinutes = 1800

    var id: Int { rawValue }

    var duration: TimeInterval { TimeInterval(rawValue) }

    var label: String {
        switch self {
        case .manual: return "Manual"
        case .oneMinute: return "1 minute"
        case .twoMinutes: return "2 minutes"
        case .fiveMinutes: return "5 minutes"
        case .tenMinutes: return "10 minutes"
        case .fifteenMinutes: return "15 minutes"
        case .thirtyMinutes: return "30 minutes"
        }
    }

    static let defaultValue: AutoRefreshInterval = .fiveMinutes
}

// MARK: - Launch At Startup State

enum LaunchAtStartupState: Equatable {
    case enabled
    case disabled
    case requiresApproval
    case unsupported
}

// MARK: - Menu Bar Visibility

enum MenuBarVisibility {
    static let paceRevealEnabledKey = "paceRevealEnabled"
    static let paceRevealAboveKey = "paceRevealAbove"
    static let paceRevealBelowKey = "paceRevealBelow"
    static let defaultPaceRevealAbove: Double = 10
    static let defaultPaceRevealBelow: Double = -10
    static let resetRevealEnabledKey = "resetRevealEnabled"
    static let resetRevealBelowKey = "resetRevealBelow"
    static let defaultResetRevealBelow: Double = 5
    static let nearingResetRevealEnabledKey = "nearingResetRevealEnabled"
    static let nearingResetRevealHoursKey = "nearingResetRevealHours"
    static let defaultNearingResetRevealHours: Double = 24

    static func defaultsKey(for provider: ProviderKind) -> String {
        let base = "menuBarShow"
        let lettersAndDigits = provider.rawValue.filter { $0.isLetter || $0.isNumber }
        return base + lettersAndDigits
    }

    static func isTicked(_ provider: ProviderKind, userDefaults: UserDefaults = .standard) -> Bool {
        let key = defaultsKey(for: provider)
        return userDefaults.object(forKey: key) as? Bool ?? true
    }

    /// Key for the per-provider option that reduces the menu bar pill to the
    /// long window's percentage alone.
    static func longWindowOnlyKey(for provider: ProviderKind) -> String {
        let lettersAndDigits = provider.rawValue.filter { $0.isLetter || $0.isNumber }
        return "menuBarLongWindowOnly" + lettersAndDigits
    }

    static func showsLongWindowOnly(_ provider: ProviderKind, userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: longWindowOnlyKey(for: provider))
    }

    static func showsInMenuBar(_ snapshot: ProviderSnapshot, userDefaults: UserDefaults = .standard, now: Date = .now) -> Bool {
        if isTicked(snapshot.provider, userDefaults: userDefaults) {
            return true
        }

        let window = snapshot.pacingWindow

        // Pace reveal
        if userDefaults.bool(forKey: paceRevealEnabledKey) {
            if let delta = UsagePacing.delta(for: window, now: now) {
                let above = userDefaults.object(forKey: paceRevealAboveKey) as? Double ?? defaultPaceRevealAbove
                let below = userDefaults.object(forKey: paceRevealBelowKey) as? Double ?? defaultPaceRevealBelow
                if delta > above || delta < below {
                    return true
                }
            }
        }

        // Reset reveal
        if userDefaults.bool(forKey: resetRevealEnabledKey) {
            if let pct = window.usedPercentage {
                let threshold = userDefaults.object(forKey: resetRevealBelowKey) as? Double ?? defaultResetRevealBelow
                if pct < threshold {
                    return true
                }
            }
        }

        // Nearing-reset reveal
        if userDefaults.bool(forKey: nearingResetRevealEnabledKey) {
            if let resetsAt = window.resetsAt {
                let hours = userDefaults.object(forKey: nearingResetRevealHoursKey) as? Double ?? defaultNearingResetRevealHours
                let threshold = hours * 60 * 60 // convert to seconds
                let distance = resetsAt.timeIntervalSince(now)
                if distance < threshold {
                    return true
                }
            }
        }

        return false
    }
}

// MARK: - Usage Pacing

enum UsagePacing {
    static func delta(for window: UsageWindow, now: Date = .now) -> Double? {
        guard let duration = window.kind.pacingWindowDuration,
              let usedPercentage = window.usedPercentage,
              let resetsAt = window.resetsAt else {
            return nil
        }

        let timeRemaining = (resetsAt.timeIntervalSince1970 - now.timeIntervalSince1970) / duration * 100
        let timeRemainingClamped = max(0, min(100, timeRemaining))

        let usageRemaining = 100 - usedPercentage
        let usageRemainingClamped = max(0, min(100, usageRemaining))

        return usageRemainingClamped - timeRemainingClamped
    }

    static func formattedDelta(for window: UsageWindow, now: Date = .now) -> String? {
        guard let delta = delta(for: window, now: now) else {
            return nil
        }

        let rounded = round(delta)
        if abs(rounded) < 0.5 {
            return "0%"
        }

        let sign = rounded >= 0 ? "+" : ""
        return "\(sign)\(Int(rounded))%"
    }
}

struct BankedReset: Identifiable, Sendable, Equatable, Encodable {
    let id: String
    let title: String
    var detail: String? = nil
    var grantedAt: Date? = nil
    var expiresAt: Date? = nil
    var status: String = "unknown"
    var usable: Bool = false
    var remaining: Int = 0
    var note: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, status, usable, remaining, note
        case detail = "description"
        case grantedAt = "granted_at"
        case expiresAt = "expires_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(detail, forKey: .detail)
        try c.encode(grantedAt, forKey: .grantedAt)
        try c.encode(expiresAt, forKey: .expiresAt)
        try c.encode(status, forKey: .status)
        try c.encode(usable, forKey: .usable)
        try c.encode(remaining, forKey: .remaining)
        try c.encode(note, forKey: .note)
    }

    static func validID(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) == id.startIndex..<id.endIndex
    }
}

enum BankedResetOutcome: String, Sendable, CaseIterable {
    case reset, alreadyRedeemed = "already_redeemed", nothingToReset = "nothing_to_reset"
    case noCredit = "no_credit", cooldown, ineligible, unavailable
    case rateLimited = "rate_limited", unconfirmed, error, notFound = "not_found", notUsable = "not_usable"

    var applied: Bool { self == .reset || self == .alreadyRedeemed }
    var httpStatus: Int {
        switch self {
        case .notFound: 404
        case .notUsable: 409
        case .rateLimited, .unconfirmed, .error: 502
        default: 200
        }
    }

    func message(provider: ProviderKind, detail: String? = nil) -> String {
        let p = provider.rawValue
        switch self {
        case .reset: return "\(p) reset applied."
        case .alreadyRedeemed: return "This \(p) reset was already applied."
        case .nothingToReset: return "\(p) has nothing to reset right now; the reset was kept."
        case .noCredit: return "\(p) reports no reset credits available."
        case .cooldown: return "\(p) allows another reset later; the reset was kept."
        case .ineligible, .unavailable: return "\(p) declined the reset; it was kept." + (detail.map { " (\($0))" } ?? "")
        case .rateLimited: return "\(p) rate limited the request; nothing was applied. Try again shortly."
        case .unconfirmed: return "Couldn't confirm whether the \(p) reset was applied. Check usage before trying again."
        case .error: return "\(p) reset failed: \(detail ?? "Unknown error.")"
        case .notFound: return "That reset is no longer listed. Refresh and try again."
        case .notUsable: return "That reset can't be applied right now." + (detail.map { " " + $0 } ?? "")
        }
    }
}

struct BankedResetUpstreamResult: Sendable {
    let outcome: BankedResetOutcome
    var detail: String? = nil
}

protocol BankedResetApplying: Sendable {
    func apply(id: String, idempotencyKey: String) async -> BankedResetUpstreamResult
}

struct UnavailableBankedResetApplier: BankedResetApplying {
    func apply(id: String, idempotencyKey: String) async -> BankedResetUpstreamResult {
        .init(outcome: .error, detail: "Reset applier is not configured.")
    }
}

struct BankedResetApplyResult {
    let provider: ProviderKind
    let resetID: String
    let outcome: BankedResetOutcome
    let message: String
    let usage: ProviderSnapshot
    var applied: Bool { outcome.applied }
}

enum BankedResetAutoApplyPolicy {
    static func isDue(_ reset: BankedReset, now: Date, leadMinutes: Int,
                      completed: Bool = false, lastAttempt: Date? = nil) -> Bool {
        guard reset.usable, !completed, let expiry = reset.expiresAt,
              expiry > now, expiry.timeIntervalSince(now) <= Double(min(60, max(1, leadMinutes))) * 60 else { return false }
        return lastAttempt.map { now.timeIntervalSince($0) >= 60 } ?? true
    }
}

struct BankedResetAutoApplyResult {
    let provider: ProviderKind
    let title: String
    let message: String
    let date: Date
}
