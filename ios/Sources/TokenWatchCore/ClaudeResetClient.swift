import Foundation

public actor ClaudeResetClient {
    private let session: URLSession
    private let url = URL(string: "https://claude-resets.com/api/resets")!
    private var nextAttempt: Date?

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(now: Date = Date()) async throws -> ClaudeResetFeed {
        if let nextAttempt, now < nextAttempt { throw ResetError.retryLater(nextAttempt) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await ResetHTTP.load(request, session: session)
        if response.statusCode == 429 {
            let seconds = ResetHTTP.retryDelay(response.value(forHTTPHeaderField: "Retry-After"), now: now)
            let retry = now.addingTimeInterval(TimeInterval(seconds))
            nextAttempt = retry
            throw ResetError.rateLimited(retry)
        }
        nextAttempt = nil
        guard response.statusCode == 200 else { throw ResetError.server(response.statusCode) }
        return try ClaudeResetFeed.decode(data, now: now)
    }
}
