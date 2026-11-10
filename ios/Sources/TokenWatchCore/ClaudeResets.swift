import Foundation

public struct ClaudeReset: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: ResetKind
    public let announcedAt: Date
    public let usableUntil: Date?
    public let scope: String?
    public let sourceURL: URL?
    public let text: String
    public let provisional: Bool

    public init(id: String, kind: ResetKind = .regular, announcedAt: Date, usableUntil: Date? = nil,
                scope: String? = nil, sourceURL: URL? = nil, text: String = "", provisional: Bool = false) {
        self.id = id
        self.kind = kind
        self.announcedAt = announcedAt
        self.usableUntil = usableUntil
        self.scope = scope
        self.sourceURL = sourceURL
        self.text = text
        self.provisional = provisional
    }
}

public struct ClaudeResetFeed: Codable, Equatable, Sendable {
    public private(set) var resets: [ClaudeReset]
    public private(set) var detectorFresh: Bool

    public init() {
        resets = []
        detectorFresh = true
    }

    public init(resets: [ClaudeReset], detectorFresh: Bool) {
        self.resets = Array(resets.sorted { $0.announcedAt > $1.announcedAt }.prefix(64))
        self.detectorFresh = detectorFresh
    }

    public var latest: ClaudeReset? { resets.first }

    public func openBanked(now: Date) -> [ClaudeReset] {
        resets.filter { $0.kind == .banked && ($0.usableUntil.map { $0 > now } ?? false) }
            .sorted { $0.usableUntil! < $1.usableUntil! }
    }

    public static func decode(_ data: Data, now: Date) throws -> Self {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let providers = root?["providers"] as? [String: Any],
              let claude = providers["claude"] as? [String: Any],
              let events = claude["events"] as? [Any] else {
            throw ResetError.invalidResponse("Claude events are missing.")
        }
        var resets: [ClaudeReset] = []
        var seen: Set<String> = []
        for raw in events {
            guard let event = raw as? [String: Any], event["kind"] as? String == "reset",
                  let id = event["id"] as? String, !id.isEmpty, id.count <= 128,
                  let dateText = event["date"] as? String,
                  let date = try? ResetDate.parse(dateText), date <= now.addingTimeInterval(300) else { continue }
            let kind: ResetKind
            if let resetType = event["resetType"] {
                guard resetType as? String == "banked" else { continue }
                kind = .banked
            } else {
                kind = .regular
            }
            guard seen.insert(id).inserted else { continue }
            let until = (event["usableUntil"] as? String).flatMap { try? ResetDate.parse($0) }
            let rawURL = event["url"] as? String
            let parsedURL = rawURL.flatMap(URL.init(string:))
            let url = parsedURL.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil ? $0 : nil }
            resets.append(ClaudeReset(id: id, kind: kind, announcedAt: date, usableUntil: until,
                                      scope: (event["scope"] as? String).map { String($0.prefix(80)) },
                                      sourceURL: url, text: String((event["note"] as? String ?? "").prefix(500)),
                                      provisional: event["verification"] as? String == "provisional"))
        }
        let meta = root?["meta"] as? [String: Any]
        let detector = meta?["detector"] as? [String: Any]
        return Self(resets: resets, detectorFresh: detector?["status"] as? String == "fresh")
    }
}
