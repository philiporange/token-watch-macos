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

public struct ProviderUsage: Codable, Equatable, Identifiable, Sendable {
    public let provider: String
    public let fiveHour: UsageWindow
    public let weekly: UsageWindow
    public let modelWindows: [ModelWindow]
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
    }
}

/// Decodes the Mac's flattened provider response, including absent readings and reset dates.
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public let providers: [ProviderUsage]
    public let lastUpdated: Date?
    public static let routeKeys = ["claude", "codex", "gemini", "muse", "zai", "alicloud", "commandcode"]

    struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
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
        try container.encodeIfPresent(lastUpdated, forKey: Key("last_updated"))
        for provider in providers {
            let key = provider.provider.lowercased().filter { $0.isLetter || $0.isNumber }
            try container.encode(provider, forKey: Key(key))
        }
    }

    public static func decode(_ data: Data) throws -> Self {
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
        return try decoder.decode(Self.self, from: data)
    }
}
