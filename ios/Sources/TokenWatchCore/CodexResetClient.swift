import Foundation

public enum ResetError: LocalizedError, Equatable {
    case invalidResponse(String)
    case server(Int)
    case rateLimited(Date)
    case retryLater(Date)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse(let detail): "Codex reset data was invalid: \(detail)"
        case .server(let code): "Codex reset service returned HTTP \(code)."
        case .rateLimited(let date), .retryLater(let date):
            "Codex reset service asked us to retry after \(date.formatted())."
        }
    }
}

public struct ResetFetchResult: Sendable {
    public let status: ResetStatus
    public let history: [ResetEvent]

    public init(status: ResetStatus, history: [ResetEvent]) {
        self.status = status
        self.history = history
    }
}

public actor CodexResetClient {
    private let session: URLSession
    private let baseURL: URL
    private var cachedStatus: ResetStatus?
    private var etag: String?
    private var nextAttempt: Date?

    public init(session: URLSession = .shared) {
        self.session = session
        self.baseURL = URL(string: "https://codex-resets.com/api/v1")!
    }

    public func fetch(tracker: ResetTracker, now: Date = Date()) async throws -> ResetFetchResult {
        if let nextAttempt, now < nextAttempt { throw ResetError.retryLater(nextAttempt) }
        var request = URLRequest(url: baseURL.appendingPathComponent("status"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await send(request, now: now)
        let status: ResetStatus
        if response.statusCode == 304 {
            guard let cachedStatus, cachedStatus.generatedAt >= now.addingTimeInterval(-900),
                  cachedStatus.generatedAt <= now.addingTimeInterval(300),
                  tracker.generatedAt.map({ cachedStatus.generatedAt >= $0 }) ?? true else {
                self.cachedStatus = nil
                etag = nil
                throw ResetError.invalidResponse("Cached status is unavailable or stale.")
            }
            status = cachedStatus
        } else {
            guard response.statusCode == 200 else { throw ResetError.server(response.statusCode) }
            status = try ResetStatus.decode(data, now: now, previousGeneratedAt: tracker.generatedAt)
            cachedStatus = status
            etag = response.value(forHTTPHeaderField: "ETag")
        }
        let history = tracker.requiresHistory(for: status)
            ? try await fetchHistory(since: tracker.pending.map(\.announcedAt).min()!, now: now) : []
        return ResetFetchResult(status: status, history: history)
    }

    private func fetchHistory(since: Date, now: Date) async throws -> [ResetEvent] {
        var records: [ResetEvent] = []
        var cursor: String?
        var seen: Set<String> = []
        for _ in 0..<10 {
            var parts = URLComponents(url: baseURL.appendingPathComponent("resets"), resolvingAgainstBaseURL: false)!
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            parts.queryItems = [URLQueryItem(name: "limit", value: "100"),
                                URLQueryItem(name: "order", value: "desc"),
                                URLQueryItem(name: "from", value: formatter.string(from: since))]
            if let cursor { parts.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
            var request = URLRequest(url: parts.url!, cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: 10)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await send(request, now: now)
            guard response.statusCode == 200 else { throw ResetError.server(response.statusCode) }
            let page = try JSONDecoder().decode(HistoryPage.self, from: data)
            guard page.meta.apiVersion == "v1" else {
                throw ResetError.invalidResponse("Unsupported reset history version.")
            }
            records += try page.data.map { try $0.event(scheduled: false) }
            if !page.pagination.hasMore { return records }
            guard let next = page.pagination.nextCursor, !next.isEmpty, next.count <= 1024,
                  seen.insert(next).inserted else {
                throw ResetError.invalidResponse("Invalid or repeated reset history cursor.")
            }
            cursor = next
        }
        throw ResetError.invalidResponse("Reset history exceeded ten pages.")
    }

    private func send(_ request: URLRequest, now: Date) async throws -> (Data, HTTPURLResponse) {
        let (bytes, rawResponse) = try await session.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse else {
            throw ResetError.invalidResponse("Missing HTTP response.")
        }
        guard response.expectedContentLength <= 524_288 else {
            throw ResetError.invalidResponse("Response exceeds 512 KiB.")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 524_288 else {
                throw ResetError.invalidResponse("Response exceeds 512 KiB.")
            }
            data.append(byte)
        }
        if response.statusCode == 429 {
            let seconds = Self.retryDelay(response.value(forHTTPHeaderField: "Retry-After"), now: now)
            let retry = now.addingTimeInterval(TimeInterval(seconds))
            nextAttempt = retry
            throw ResetError.rateLimited(retry)
        }
        nextAttempt = nil
        return (data, response)
    }

    private static func retryDelay(_ value: String?, now: Date) -> Int {
        if let value, let seconds = Int(value) { return max(60, seconds) }
        if let value, let date = HTTPDate.parse(value) {
            return max(60, Int(date.timeIntervalSince(now)))
        }
        return 300
    }
}

private enum HTTPDate {
    static func parse(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

private struct HistoryPage: Decodable {
    struct Meta: Decodable {
        let apiVersion: String
        enum CodingKeys: String, CodingKey { case apiVersion = "api_version" }
    }
    struct Pagination: Decodable {
        let hasMore: Bool
        let nextCursor: String?
        enum CodingKeys: String, CodingKey { case hasMore = "has_more", nextCursor = "next_cursor" }
    }
    let data: [APIReset]
    let meta: Meta
    let pagination: Pagination
}
