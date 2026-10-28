import Foundation
import XCTest
@testable import TokenWatchCore

final class CodexResetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_155_000)

    private func event(_ id: String, kind: ResetKind = .regular, at: Date? = nil,
                       scheduled: Date? = nil, url: String? = nil) -> ResetEvent {
        ResetEvent(id: id, kind: kind, announcedAt: at ?? now.addingTimeInterval(-120),
                   scheduledFor: scheduled, sourceURL: url.flatMap(URL.init(string:)), text: id)
    }

    private func status(_ scheduled: ResetEvent?, _ latest: ResetEvent? = nil,
                        generated: Date? = nil) -> ResetStatus {
        ResetStatus(generatedAt: generated ?? now, scheduled: scheduled, latest: latest)
    }

    func testLiveFixtureAndStrictStatusValidation() throws {
        let fixture = Data("""
        {"data":{"latest_reset":{"id":"observed-2114588174249071102","reset_type":"regular","announced_at":"2026-10-26T07:00:00.000Z","text":"Limits reset","source":{"type":"observed","url":"https://x.com/thsottiaux/status/2114588174249071102"}},"scheduled_reset":{"id":"2115273253711409208","status":"scheduled","reset_type":"regular","announced_at":"2026-10-28T02:43:38.000Z","scheduled_for":"2026-10-28T07:00:00.000Z","text":"Lands by midnight PST.","source":{"type":"x_post","url":"https://x.com/thsottiaux/status/2115273253711409208"}}},"meta":{"api_version":"v1","generated_at":"2026-10-28T03:48:39.769Z"}}
        """.utf8)
        let reference = try ResetDate.parse("2026-10-28T03:49:00Z")
        let parsed = try ResetStatus.decode(fixture, now: reference)
        XCTAssertEqual(parsed.scheduled?.id, "2115273253711409208")
        XCTAssertEqual(parsed.latest?.id, "observed-2114588174249071102")
        XCTAssertNotNil(parsed.scheduled?.scheduledFor)

        let baseline = String(decoding: fixture, as: UTF8.self)
        XCTAssertNotNil(try ResetStatus.decode(Data(baseline.replacingOccurrences(of: ".769Z", with: "Z").utf8), now: reference).generatedAt)
        XCTAssertNil(try ResetStatus.decode(Data(baseline.replacingOccurrences(of: "\"scheduled_reset\":{", with: "\"scheduled_reset\":null,\"ignored\":{").utf8), now: reference).scheduled)
        for invalid in [
            baseline.replacingOccurrences(of: "\"scheduled_reset\":", with: "\"missing_schedule\":"),
            baseline.replacingOccurrences(of: "\"v1\"", with: "\"v2\""),
            baseline.replacingOccurrences(of: "2026-10-28T03:48:39.769Z", with: "2026-10-28T03:48:39.769"),
            baseline.replacingOccurrences(of: "2026-10-28T03:48:39.769Z", with: "2026-10-27T03:48:39Z"),
            baseline.replacingOccurrences(of: "2026-10-28T03:48:39.769Z", with: "2026-10-28T04:00:00Z"),
            baseline.replacingOccurrences(of: "https://x.com/thsottiaux/status/2115273253711409208", with: "file:///tmp/test")
        ] {
            XCTAssertThrowsError(try ResetStatus.decode(Data(invalid.utf8), now: reference))
        }
        XCTAssertThrowsError(try ResetStatus.decode(fixture, now: reference,
                                                    previousGeneratedAt: reference))
    }

    func testPendingPersistsAndRequiresRegularExecutionEvidence() {
        let proposed = event("notice", scheduled: now.addingTimeInterval(60))
        let baseline = event("before", at: now.addingTimeInterval(-3600))
        var tracker = ResetTracker()
        tracker.apply(status(proposed, baseline), now: now)
        XCTAssertEqual(tracker.upcoming?.id, "notice")
        tracker.apply(status(nil, event("bank", kind: .banked)), now: now.addingTimeInterval(120))
        XCTAssertEqual(tracker.pending.map(\.id), ["notice"])
        tracker.apply(status(nil, baseline), now: now.addingTimeInterval(120))
        XCTAssertEqual(tracker.pending.map(\.id), ["notice"])
        tracker.apply(status(nil, baseline), history: [event("future", at: now.addingTimeInterval(600))], now: now)
        XCTAssertEqual(tracker.pending.map(\.id), ["notice"])
        tracker.apply(status(nil, event("after", at: now.addingTimeInterval(121))), now: now.addingTimeInterval(180))
        XCTAssertTrue(tracker.pending.isEmpty)
        XCTAssertEqual(tracker.completedIDs, ["notice"])
        tracker.apply(status(proposed, baseline), now: now.addingTimeInterval(180))
        XCTAssertTrue(tracker.pending.isEmpty)
    }

    func testUpdatedSchedulePreservesBaselineAndMatchingEvidenceConfirms() {
        let original = event("123", scheduled: now.addingTimeInterval(60), url: "https://x.com/a")
        let updated = event("123", scheduled: now.addingTimeInterval(300), url: "https://x.com/a")
        let baseline = event("before", at: now.addingTimeInterval(-3600))
        var tracker = ResetTracker()
        tracker.apply(status(original, baseline), now: now)
        tracker.apply(status(updated, baseline), now: now)
        XCTAssertEqual(tracker.upcoming?.scheduledFor, updated.scheduledFor)
        tracker.apply(status(nil, baseline), history: [event("observed-123")], now: now)
        XCTAssertEqual(tracker.completedIDs, ["123"])

        var byURL = ResetTracker()
        byURL.apply(status(original, baseline), now: now)
        byURL.apply(status(nil, baseline), history: [event("other", url: "https://x.com/a")], now: now)
        XCTAssertEqual(byURL.completedIDs, ["123"])
    }

    func testTrackerRoundTripKeepsBaseline() throws {
        var tracker = ResetTracker()
        tracker.apply(status(event("notice"), event("before", at: now.addingTimeInterval(-3600))), now: now)
        var decoded = try JSONDecoder().decode(ResetTracker.self, from: JSONEncoder().encode(tracker))
        decoded.apply(status(nil, event("before", at: now.addingTimeInterval(-3600))), now: now)
        XCTAssertEqual(decoded.pending.map(\.id), ["notice"])
    }

    func testClientFetchesPaginatedHistoryAndRejectsRepeatedCursor() async throws {
        let generated = "2026-10-28T03:48:39Z"
        let reference = try ResetDate.parse("2026-10-28T03:49:00Z")
        let statusJSON = """
        {"meta":{"api_version":"v1","generated_at":"\(generated)"},"data":{"scheduled_reset":null,"latest_reset":null}}
        """
        let record = """
        {"id":"new","reset_type":"regular","announced_at":"2026-10-28T03:00:00Z","text":"Done","source":{"type":"observed"}}
        """
        let first = """
        {"meta":{"api_version":"v1"},"data":[\(record)],"pagination":{"has_more":true,"next_cursor":"abc"}}
        """
        let second = """
        {"meta":{"api_version":"v1"},"data":[],"pagination":{"has_more":false,"next_cursor":null}}
        """
        let session = mockSession { request in
            if request.url?.path.hasSuffix("/status") == true { return (200, [:], statusJSON) }
            return (200, [:], request.url?.query?.contains("cursor=abc") == true ? second : first)
        }
        var tracker = ResetTracker()
        tracker.apply(status(event("pending", at: reference.addingTimeInterval(-4000))), now: reference)
        let result = try await CodexResetClient(session: session).fetch(tracker: tracker, now: reference)
        XCTAssertEqual(result.history.map(\.id), ["new"])

        let repeated = mockSession { request in
            (200, [:], request.url?.path.hasSuffix("/status") == true ? statusJSON : first)
        }
        do {
            _ = try await CodexResetClient(session: repeated).fetch(tracker: tracker, now: reference)
            XCTFail("Repeated history cursor should fail")
        } catch let error as ResetError {
            guard case .invalidResponse = error else { return XCTFail("Wrong error: \(error)") }
        }
    }

    func testClientHonorsRateLimitWithoutRetrying() async throws {
        let reference = try ResetDate.parse("2026-10-28T03:49:00Z")
        let lock = NSLock()
        var calls = 0
        let session = mockSession { _ in
            lock.lock()
            calls += 1
            lock.unlock()
            return (429, ["Retry-After": "120"], "")
        }
        let client = CodexResetClient(session: session)
        do {
            _ = try await client.fetch(tracker: ResetTracker(), now: reference)
            XCTFail("Rate limit should fail")
        } catch let error as ResetError {
            guard case .rateLimited(let retry) = error else { return XCTFail("Wrong error: \(error)") }
            XCTAssertEqual(retry, reference.addingTimeInterval(120))
        }
        do {
            _ = try await client.fetch(tracker: ResetTracker(), now: reference.addingTimeInterval(30))
            XCTFail("Backoff should prevent request")
        } catch let error as ResetError {
            guard case .retryLater = error else { return XCTFail("Wrong error: \(error)") }
        }
        XCTAssertEqual(calls, 1)
    }

    func testClientHonorsHTTPDateRetryAfter() async throws {
        let reference = try ResetDate.parse("2026-10-28T03:49:00Z")
        let session = mockSession { _ in
            (429, ["Retry-After": "Wed, 28 Oct 2026 03:52:00 GMT"], "")
        }
        do {
            _ = try await CodexResetClient(session: session).fetch(tracker: ResetTracker(), now: reference)
            XCTFail("Rate limit should fail")
        } catch let error as ResetError {
            guard case .rateLimited(let retry) = error else { return XCTFail("Wrong error: \(error)") }
            XCTAssertEqual(retry, reference.addingTimeInterval(180))
        }
    }

    func testUnchangedBankedLatestStillFetchesHistoryAgainstOriginalBaseline() async throws {
        let reference = try ResetDate.parse("2026-10-28T03:49:00Z")
        let pending = event("pending", at: reference.addingTimeInterval(-4000))
        let baseline = event("original", at: reference.addingTimeInterval(-5000))
        let banked = event("banked", kind: .banked, at: reference.addingTimeInterval(-100))
        var tracker = ResetTracker()
        tracker.apply(status(pending, baseline, generated: reference.addingTimeInterval(-60)), now: reference)
        tracker.apply(status(pending, banked, generated: reference.addingTimeInterval(-30)), now: reference)
        XCTAssertEqual(tracker.latest?.id, "banked")

        let body = """
        {"meta":{"api_version":"v1","generated_at":"2026-10-28T03:49:00Z"},"data":{"scheduled_reset":{"id":"pending","status":"scheduled","reset_type":"regular","announced_at":"2026-10-28T02:43:38Z","scheduled_for":null,"text":"pending","source":{"type":"x_post"}},"latest_reset":{"id":"banked","reset_type":"banked","announced_at":"2026-10-28T03:47:20Z","text":"banked","source":{"type":"observed"}}}}
        """
        let history = """
        {"meta":{"api_version":"v1"},"data":[{"id":"regular-new","reset_type":"regular","announced_at":"2026-10-28T03:48:00Z","text":"reset","source":{"type":"observed"}}],"pagination":{"has_more":false}}
        """
        let lock = NSLock()
        var historyRequests = 0
        let session = mockSession { request in
            if request.url?.path.hasSuffix("/status") == true { return (200, [:], body) }
            lock.lock()
            historyRequests += 1
            lock.unlock()
            return (200, [:], history)
        }
        let result = try await CodexResetClient(session: session).fetch(tracker: tracker, now: reference)
        XCTAssertEqual(historyRequests, 1)
        XCTAssertEqual(result.history.map(\.id), ["regular-new"])
    }

    func testExpired304CacheDropsETagForNextFetch() async throws {
        let reference = try ResetDate.parse("2026-10-28T03:49:00Z")
        let old = """
        {"meta":{"api_version":"v1","generated_at":"2026-10-28T03:49:00Z"},"data":{"scheduled_reset":null,"latest_reset":null}}
        """
        let fresh = """
        {"meta":{"api_version":"v1","generated_at":"2026-10-28T04:06:00Z"},"data":{"scheduled_reset":null,"latest_reset":null}}
        """
        let lock = NSLock()
        var headers: [String?] = []
        let session = mockSession { request in
            lock.lock()
            headers.append(request.value(forHTTPHeaderField: "If-None-Match"))
            let count = headers.count
            lock.unlock()
            switch count {
            case 1: return (200, ["ETag": "old-tag"], old)
            case 2: return (304, [:], "")
            default: return (200, [:], fresh)
            }
        }
        let client = CodexResetClient(session: session)
        _ = try await client.fetch(tracker: ResetTracker(), now: reference)
        let later = reference.addingTimeInterval(1020)
        do {
            _ = try await client.fetch(tracker: ResetTracker(), now: later)
            XCTFail("Expired cached status must fail")
        } catch let error as ResetError {
            guard case .invalidResponse = error else { return XCTFail("Wrong error: \(error)") }
        }
        _ = try await client.fetch(tracker: ResetTracker(), now: later)
        XCTAssertEqual(headers[0], nil)
        XCTAssertEqual(headers[1], "old-tag")
        XCTAssertEqual(headers[2], nil)
    }

    private func mockSession(_ handler: @escaping (URLRequest) -> (Int, [String: String], String)) -> URLSession {
        MockResetProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockResetProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class MockResetProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, headers, body) = Self.handler!(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
