import Foundation

public struct UsageWindow: Codable, Equatable, Sendable {
    public let kind: String
    public let usedPercentage: Double?
    public let resetsAt: Date?
    public let message: String?

    public var fraction: Double? { usedPercentage.map { min(1, max(0, $0 / 100)) } }
    public var title: String {
        switch kind {
        case "5h": "Session"
        case "Month": "Monthly"
        case "Model": "Model limit"
        default: "Weekly"
        }
    }

    enum CodingKeys: String, CodingKey {
        case kind, message
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }
}

public struct ModelWindow: Codable, Equatable, Identifiable, Sendable {
    public let modelName: String
    public let window: UsageWindow
    public let isActive: Bool
    public var id: String { modelName }

    enum CodingKeys: String, CodingKey {
        case window
        case modelName = "model_name"
        case isActive = "is_active"
    }
}

public struct BankedReset: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let description: String?
    public let grantedAt: Date?
    public let expiresAt: Date?
    public let status: String
    public let usable: Bool
    public let remaining: Int
    public let note: String?

    public init(id: String, title: String, description: String? = nil, grantedAt: Date? = nil,
                expiresAt: Date? = nil, status: String = "available", usable: Bool = true,
                remaining: Int = 1, note: String? = nil) {
        self.id = id
        self.title = title
        self.description = description
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.status = status
        self.usable = usable
        self.remaining = remaining
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case id, title, description, status, usable, remaining, note
        case grantedAt = "granted_at", expiresAt = "expires_at"
    }

    var hasValidID: Bool {
        (1...128).contains(id.utf8.count) && id.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

public struct BankedResetAutoApply: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let leadMinutes: Int

    public init(enabled: Bool, leadMinutes: Int) {
        self.enabled = enabled
        self.leadMinutes = leadMinutes
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case leadMinutes = "lead_minutes"
    }
}

public struct ProviderUsage: Codable, Equatable, Identifiable, Sendable {
    public let provider: String
    public let fiveHour: UsageWindow
    public let weekly: UsageWindow
    public let modelWindows: [ModelWindow]
    public let bankedResets: [BankedReset]
    public let detail: String?
    public let paceDelta: Double?
    public let updatedAt: Date?
    public var id: String { provider }
    public var hasReadings: Bool {
        fiveHour.usedPercentage != nil || weekly.usedPercentage != nil || modelWindows.contains { $0.window.usedPercentage != nil }
    }

    enum CodingKeys: String, CodingKey {
        case provider, weekly, detail
        case fiveHour = "five_hour"
        case modelWindows = "model_windows"
        case paceDelta = "pace_delta"
        case updatedAt = "updated_at"
        case bankedResets = "banked_resets"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(String.self, forKey: .provider)
        fiveHour = try container.decode(UsageWindow.self, forKey: .fiveHour)
        weekly = try container.decode(UsageWindow.self, forKey: .weekly)
        modelWindows = try container.decode([ModelWindow].self, forKey: .modelWindows)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        paceDelta = try container.decodeIfPresent(Double.self, forKey: .paceDelta)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        bankedResets = (try container.decodeIfPresent([BankedReset].self, forKey: .bankedResets) ?? [])
            .filter(\.hasValidID)
    }
}

/// Decodes the Mac's flattened provider response, including absent readings and reset dates.
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public let providers: [ProviderUsage]
    public let lastUpdated: Date?
    public let autoApply: BankedResetAutoApply?
    public static let routeKeys = ["claude", "codex", "gemini", "muse", "zai", "alicloud", "commandcode"]

    struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private init(providers: [ProviderUsage], lastUpdated: Date?, autoApply: BankedResetAutoApply?) {
        self.providers = providers
        self.lastUpdated = lastUpdated
        self.autoApply = autoApply
    }

    public func replacingProvider(_ usage: ProviderUsage) -> Self {
        Self(providers: providers.map { $0.id == usage.id ? usage : $0 },
             lastUpdated: lastUpdated, autoApply: autoApply)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        autoApply = try container.decodeIfPresent(BankedResetAutoApply.self, forKey: Key("banked_reset_auto_apply"))
        lastUpdated = try container.decodeIfPresent(Date.self, forKey: Key("last_updated"))
        providers = try Self.routeKeys.compactMap {
            try container.decodeIfPresent(ProviderUsage.self, forKey: Key($0))
        }
        guard !providers.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "No Token Watch providers found."))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encodeIfPresent(autoApply, forKey: Key("banked_reset_auto_apply"))
        try container.encodeIfPresent(lastUpdated, forKey: Key("last_updated"))
        for provider in providers {
            let key = provider.provider.lowercased().filter { $0.isLetter || $0.isNumber }
            try container.encode(provider, forKey: Key(key))
        }
    }

    public static func decode(_ data: Data) throws -> Self {
        try makeDecoder().decode(Self.self, from: data)
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid reset date."))
        }
        return decoder
    }
}
