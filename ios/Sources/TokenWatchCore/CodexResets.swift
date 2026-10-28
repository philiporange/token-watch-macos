import Foundation

public enum ResetKind: String, Codable, Sendable {
    case regular, banked
}

public struct ResetEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: ResetKind
    public let announcedAt: Date
    public let scheduledFor: Date?
    public let sourceURL: URL?
    public let text: String

    public init(id: String, kind: ResetKind, announcedAt: Date, scheduledFor: Date? = nil,
                sourceURL: URL? = nil, text: String) {
        self.id = id
        self.kind = kind
        self.announcedAt = announcedAt
        self.scheduledFor = scheduledFor
        self.sourceURL = sourceURL
        self.text = text
    }
}

public struct ResetStatus: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let scheduled: ResetEvent?
    public let latest: ResetEvent?

    public init(generatedAt: Date, scheduled: ResetEvent?, latest: ResetEvent?) {
        self.generatedAt = generatedAt
        self.scheduled = scheduled
        self.latest = latest
    }

    public static func decode(_ data: Data, now: Date, previousGeneratedAt: Date? = nil) throws -> Self {
        let raw = try JSONDecoder().decode(StatusEnvelope.self, from: data)
        guard raw.meta.apiVersion == "v1" else { throw ResetError.invalidResponse("Unsupported reset API version.") }
        let generated = try ResetDate.parse(raw.meta.generatedAt)
        guard generated >= now.addingTimeInterval(-900), generated <= now.addingTimeInterval(300),
              previousGeneratedAt.map({ generated >= $0 }) ?? true else {
            throw ResetError.invalidResponse("Reset response is stale or from the future.")
        }
        return try Self(generatedAt: generated,
                        scheduled: raw.data.scheduled.map { try $0.event(scheduled: true) },
                        latest: raw.data.latest.map { try $0.event(scheduled: false) })
    }
}

public struct ResetTracker: Codable, Equatable, Sendable {
    public private(set) var pending: [ResetEvent] = []
    public private(set) var completedIDs: [String] = []
    public private(set) var latest: ResetEvent?
    public private(set) var generatedAt: Date?
    private var baselineIDs: [String: String] = [:]

    public init() {}

    public var upcoming: ResetEvent? {
        pending.min { ($0.scheduledFor ?? .distantFuture, $0.announcedAt) <
                      ($1.scheduledFor ?? .distantFuture, $1.announcedAt) }
    }

    func requiresHistory(for status: ResetStatus) -> Bool {
        pending.contains { item in
            status.scheduled?.id != item.id ||
                (status.latest != nil && status.latest?.id != baselineIDs[item.id])
        }
    }

    public mutating func apply(_ status: ResetStatus, history: [ResetEvent] = [], now: Date) {
        guard generatedAt.map({ status.generatedAt >= $0 }) ?? true else { return }
        if let scheduled = status.scheduled, scheduled.kind == .regular,
           !completedIDs.contains(scheduled.id) {
            if let index = pending.firstIndex(where: { $0.id == scheduled.id }) {
                let old = pending[index]
                pending[index] = ResetEvent(id: old.id, kind: old.kind, announcedAt: old.announcedAt,
                                            scheduledFor: scheduled.scheduledFor, sourceURL: old.sourceURL,
                                            text: scheduled.text)
            } else if pending.count < 32 {
                pending.append(scheduled)
                if let latestID = status.latest?.id { baselineIDs[scheduled.id] = latestID }
            }
        }
        let evidence = [status.latest].compactMap { $0 } + history
        pending.removeAll { item in
            let confirmed = evidence.contains { reset in
                guard reset.kind == .regular, reset.announcedAt >= item.announcedAt,
                      reset.announcedAt <= now else { return false }
                let matchingID = reset.id.removingObservedPrefix == item.id.removingObservedPrefix
                let matchingURL = item.sourceURL != nil && item.sourceURL == reset.sourceURL
                if matchingID || matchingURL { return true }
                let outstanding = status.scheduled?.id == item.id
                return !outstanding && reset.id != baselineIDs[item.id] &&
                    reset.announcedAt > item.announcedAt
            }
            if confirmed {
                completedIDs.append(item.id)
                baselineIDs.removeValue(forKey: item.id)
            }
            return confirmed
        }
        if completedIDs.count > 256 { completedIDs.removeFirst(completedIDs.count - 256) }
        latest = status.latest
        generatedAt = status.generatedAt
    }
}

private extension String {
    var removingObservedPrefix: String {
        hasPrefix("observed-") ? String(dropFirst("observed-".count)) : self
    }
}

enum ResetDate {
    static func parse(_ value: String) throws -> Date {
        guard value.range(of: #"(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else {
            throw ResetError.invalidResponse("Reset timestamp needs a timezone.")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        throw ResetError.invalidResponse("Invalid reset timestamp.")
    }
}

struct StatusEnvelope: Decodable {
    struct Meta: Decodable {
        let apiVersion: String
        let generatedAt: String
        enum CodingKeys: String, CodingKey { case apiVersion = "api_version", generatedAt = "generated_at" }
    }
    struct Body: Decodable {
        let scheduled: APIReset?
        let latest: APIReset?
        enum CodingKeys: String, CodingKey { case scheduled = "scheduled_reset", latest = "latest_reset" }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard values.contains(.scheduled), values.contains(.latest) else {
                throw ResetError.invalidResponse("Reset status is missing required fields.")
            }
            scheduled = try values.decodeIfPresent(APIReset.self, forKey: .scheduled)
            latest = try values.decodeIfPresent(APIReset.self, forKey: .latest)
        }
    }
    let meta: Meta
    let data: Body
}

struct APIReset: Decodable {
    struct Source: Decodable {
        let type: String
        let url: String?
    }
    let id: String
    let resetType: String
    let announcedAt: String
    let scheduledFor: String?
    let status: String?
    let text: String
    let source: Source
    enum CodingKeys: String, CodingKey {
        case id, status, text, source
        case resetType = "reset_type", announcedAt = "announced_at", scheduledFor = "scheduled_for"
    }

    func event(scheduled: Bool) throws -> ResetEvent {
        guard !id.isEmpty, id.count <= 128, let kind = ResetKind(rawValue: resetType),
              ["observed", "x_post"].contains(source.type),
              !scheduled || status == "scheduled" else {
            throw ResetError.invalidResponse("Invalid reset event.")
        }
        let url: URL?
        if let rawURL = source.url {
            guard let parsed = URL(string: rawURL), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
                  parsed.host != nil else { throw ResetError.invalidResponse("Invalid reset source URL.") }
            url = parsed
        } else { url = nil }
        return try ResetEvent(id: id, kind: kind, announcedAt: ResetDate.parse(announcedAt),
                              scheduledFor: scheduledFor.map { try ResetDate.parse($0) },
                              sourceURL: url, text: text)
    }
}
