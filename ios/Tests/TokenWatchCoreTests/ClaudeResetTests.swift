import Foundation
import XCTest
@testable import TokenWatchCore

final class ClaudeResetTests: XCTestCase {
    private let reference = Date(timeIntervalSince1970: 1_793_159_340)

    private var fixture: Data {
        Data("""
        {"providers":{"claude":{"events":[
          {"id":"regular","date":"2026-10-28T03:00:00Z","kind":"reset","scope":"Pro, Max + Team","note":"Limits reset","url":"https://x.com/ClaudeDevs/status/1","verification":"curated"},
          {"id":"banked","date":"2026-10-28T03:30:00Z","kind":"reset","resetType":"banked","usableUntil":"2026-10-29T23:59:59Z","scope":"Pro","note":"Banked credit"},
          {"id":"policy","date":"2026-10-28T03:40:00Z","kind":"policy"},
          {"id":"provisional","date":"2026-10-28T03:45:00Z","kind":"reset","verification":"provisional","url":"file:///bad"},
          {"id":"invalid","date":"no date","kind":"reset"}
        ]}},"meta":{"detector":{"status":"fresh"}}}
        """.utf8)
    }

    func testDecodeFiltersOrdersAndKeepsBankedDeadline() throws {
        let feed = try ClaudeResetFeed.decode(fixture, now: reference)
        XCTAssertEqual(feed.resets.map(\.id), ["provisional", "banked", "regular"])
        XCTAssertTrue(feed.detectorFresh)
        XCTAssertTrue(feed.latest?.provisional == true)
        XCTAssertNil(feed.latest?.sourceURL)
        XCTAssertEqual(feed.resets[1].kind, .banked)
        XCTAssertEqual(feed.resets[1].scope, "Pro")
        let deadline = try XCTUnwrap(feed.resets[1].usableUntil)
        XCTAssertEqual(feed.openBanked(now: reference).map(\.id), ["banked"])
        XCTAssertTrue(feed.openBanked(now: deadline).isEmpty)
        XCTAssertThrowsError(try ClaudeResetFeed.decode(Data(#"{"providers":{"claude":{}}}"#.utf8), now: reference))
    }

    func testClientParsesAndHandlesRateLimitAndServerError() async throws {
        let body = String(decoding: fixture, as: UTF8.self)
        let success = mockSession { _ in (200, [:], body) }
        let feed = try await ClaudeResetClient(session: success).fetch(now: reference)
        XCTAssertEqual(feed.resets.count, 3)

        let lock = NSLock()
        var calls = 0
        let limited = mockSession { _ in
            lock.lock()
            calls += 1
            lock.unlock()
            return (429, ["Retry-After": "120"], "")
        }
        let client = ClaudeResetClient(session: limited)
        do {
            _ = try await client.fetch(now: reference)
            XCTFail("Expected rate limit")
        } catch let error as ResetError {
            XCTAssertEqual(error, .rateLimited(reference.addingTimeInterval(120)))
        }
        do {
            _ = try await client.fetch(now: reference.addingTimeInterval(30))
            XCTFail("Expected backoff")
        } catch let error as ResetError {
            XCTAssertEqual(error, .retryLater(reference.addingTimeInterval(120)))
        }
        XCTAssertEqual(calls, 1)

        let failing = mockSession { _ in (503, [:], "") }
        do {
            _ = try await ClaudeResetClient(session: failing).fetch(now: reference)
            XCTFail("Expected server error")
        } catch let error as ResetError {
            XCTAssertEqual(error, .server(503))
        }
    }

    func testFeedCodableRoundTrip() throws {
        let feed = try ClaudeResetFeed.decode(fixture, now: reference)
        XCTAssertEqual(try JSONDecoder().decode(ClaudeResetFeed.self, from: JSONEncoder().encode(feed)), feed)
    }

    private func mockSession(_ handler: @escaping (URLRequest) -> (Int, [String: String], String)) -> URLSession {
        MockClaudeProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockClaudeProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class MockClaudeProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, headers, body) = Self.handler!(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
