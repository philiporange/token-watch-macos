import Foundation
import XCTest
@testable import TokenWatchCore

private let historyFixture = Data("""
{
  "generated_at":"2026-10-29T12:00:00Z", "range":"7d", "since":"2026-10-22T12:00:00Z",
  "rules":{"interval_minutes":60,"change_points":1},
  "series":[{
    "id":"claude.weekly", "provider":"claude", "provider_name":"Claude", "window":"weekly",
    "label":"Weekly", "kind":"Week",
    "points":[{"t":"2026-10-28T12:00:00Z","used":10,"resets_at":"2026-11-03T00:00:00Z"},
              {"t":"2026-10-29T00:00:00.125Z","used":20,"resets_at":"2026-11-03T00:00:00Z"}],
    "current":{"t":"2026-10-29T12:00:00Z","used":30,"resets_at":"2026-11-03T00:00:00Z"},
    "projections":[
      {"method":"average","rate_per_hour":0.5,"at_reset":84,"limit_at":null,
       "from":{"t":"2026-10-29T12:00:00Z","used":30},"to":{"t":"2026-11-03T00:00:00Z","used":84}},
      {"method":"trend","rate_per_hour":0.8333333333,"at_reset":120,"limit_at":"2026-11-01T00:00:00Z",
       "from":{"t":"2026-10-29T12:00:00Z","used":30},"to":{"t":"2026-11-01T00:00:00Z","used":100}}
    ]
  }, {
    "id":"codex.five_hour", "provider":"codex", "provider_name":"Codex", "window":"five_hour",
    "label":"5-hour", "kind":"5h", "points":[],
    "current":{"t":"2026-10-29T12:00:00Z","used":0,"resets_at":null}, "projections":[]
  }]
}
""".utf8)

/// Fully intercepts requests in memory; no HTTP or provider connection is made.
private final class HistoryStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = request.value(forHTTPHeaderField: "Authorization") == "Bearer rejected" ? 401 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: historyFixture)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class UsageHistoryTests: XCTestCase, @unchecked Sendable {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    func testFullContractResponseAndAllTimeNullSinceDecode() throws {
        let history = try UsageHistory.decode(historyFixture)
        XCTAssertEqual(history.range, .week)
        XCTAssertEqual(history.generatedAt, date("2026-10-29T12:00:00Z"))
        XCTAssertEqual(history.since, date("2026-10-22T12:00:00Z"))
        XCTAssertEqual(history.rules.intervalMinutes, 60)
        XCTAssertEqual(history.rules.changePoints, 1)
        let weekly = history.series[0]
        XCTAssertEqual(weekly.id, "claude.weekly")
        XCTAssertEqual(weekly.providerName, "Claude")
        XCTAssertEqual(weekly.points[1].t.timeIntervalSince1970.truncatingRemainder(dividingBy: 1), 0.125, accuracy: 0.001)
        XCTAssertNil(weekly.projections[0].limitAt)
        XCTAssertNil(weekly.projections[0].from.resetsAt)
        XCTAssertEqual(weekly.projections[1].atReset, 120)
        XCTAssertEqual(history.series[1].projections, [])
        XCTAssertNil(history.series[1].current.resetsAt)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: historyFixture) as? [String: Any])
        object["range"] = "all"
        object["since"] = NSNull()
        let all = try UsageHistory.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(all.range, .all)
        XCTAssertNil(all.since)
        XCTAssertEqual(all.xDomain(now: all.generatedAt).lowerBound, all.series[0].points[0].t)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let wholeSecond = history.series[0].projections[0]
        XCTAssertEqual(try UsageSnapshot.makeDecoder().decode(UsageHistoryProjection.self, from: encoder.encode(wholeSecond)), wholeSecond)
        XCTAssertEqual(UsageHistoryRange.allCases.map(\.label), ["24h", "7d", "30d", "90d", "1y", "All"])
    }

    func testHistoryRequestUsesRangeOptionalProviderPairedGetAndTimeout() throws {
        let connection = try MacConnection(address: "mac.invalid:8037", token: " test-key ")
        let request = try connection.historyRequest(range: .year, provider: "commandcode")
        XCTAssertEqual(request.url?.absoluteString, "http://mac.invalid:8037/history?range=365d&provider=commandcode")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.timeoutInterval, 20)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        let all = try connection.historyRequest(range: .all)
        XCTAssertEqual(all.url?.query, "range=all")
        let escaped = try connection.historyRequest(range: .day, provider: "a&range=all")
        let items = URLComponents(url: escaped.url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.count, 2)
        XCTAssertEqual(items?.last?.value, "a&range=all")
    }

    func testHistoryClientFetchAndRejectedKeyUseOnlyStubSession() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HistoryStubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let accepted = try MacConnection(address: "mac.invalid", token: "accepted")
        let history = try await UsageClient.history(accepted, range: .week, provider: "claude", session: session)
        XCTAssertEqual(history.series.count, 2)
        do {
            let rejected = try MacConnection(address: "mac.invalid", token: "rejected")
            _ = try await UsageClient.history(rejected, range: .week, session: session)
            XCTFail("Expected authentication rejection")
        } catch {
            XCTAssertEqual(error as? ConnectionError, .rejectedKey)
        }
    }

    func testHistoryErrorMapping() throws {
        let url = URL(string: "http://mac.invalid/history")!
        for code in [401, 403, 404, 500] {
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
            XCTAssertThrowsError(try UsageClient.decodeHistory(historyFixture, response: response)) {
                XCTAssertEqual($0 as? ConnectionError, [401, 403].contains(code) ? .rejectedKey : .server(code))
            }
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try UsageClient.decodeHistory(Data("{}".utf8), response: response)) {
            XCTAssertEqual($0 as? ConnectionError, .badResponse)
        }
    }

    func testDomainsPlottingAndProjectionClipping() throws {
        let history = try UsageHistory.decode(historyFixture)
        let now = history.generatedAt
        for range in UsageHistoryRange.allCases where range != .all {
            let span = try XCTUnwrap(range.duration)
            XCTAssertEqual(range.xDomain(now: now).lowerBound, now.addingTimeInterval(-span))
            XCTAssertEqual(range.xDomain(now: now).upperBound, now.addingTimeInterval(span / 4))
        }
        XCTAssertEqual(history.xDomain(now: now), UsageHistoryRange.week.xDomain(now: now))
        let series = history.series[0]
        XCTAssertEqual(series.plottedLine.count, 3)
        XCTAssertEqual(series.plottedLine.last, series.current)
        XCTAssertEqual(history.series[1].plottedLine, [history.series[1].current])
        let alreadyStored = UsageHistorySeries(id: series.id, provider: series.provider, providerName: series.providerName,
            window: series.window, label: series.label, kind: series.kind, points: [series.current],
            current: series.current, projections: [])
        XCTAssertEqual(alreadyStored.plottedLine, [series.current])
        let first = try XCTUnwrap(series.points.first).t
        let domain = UsageHistoryRange.all.xDomain(now: now, firstPoint: first)
        XCTAssertEqual(domain.lowerBound, first)
        XCTAssertEqual(domain.upperBound, now.addingTimeInterval(now.timeIntervalSince(first) / 4))
        XCTAssertGreaterThan(UsageHistoryRange.all.xDomain(now: now).upperBound, now)
        let average = series.projections[0]
        let end = now.addingTimeInterval(3600 * 12)
        let clipped = average.clipped(to: end)
        XCTAssertEqual(clipped.count, 2)
        XCTAssertEqual(clipped[0], average.from)
        XCTAssertEqual(clipped[1].t, end)
        XCTAssertEqual(clipped[1].used, 36, accuracy: 0.01)
        XCTAssertEqual(average.clipped(to: now.addingTimeInterval(-1)), [])
        XCTAssertEqual(average.clipped(to: average.to.t), [average.from, average.to])
        XCTAssertEqual(history.series[1].noProjectionReason, "No reset time")
        XCTAssertEqual(alreadyStored.noProjectionReason, "Not enough history yet")
    }

    func testV2ProjectionSummariesAndLookbackLabels() throws {
        let series = try UsageHistory.decode(historyFixture).series[0]
        let utc = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(series.projections[0].summary(kind: series.kind, reset: series.current.resetsAt, timeZone: utc),
                       "Average pace 0.5%/h · 84% at reset Tue 3 Nov 00:00")
        XCTAssertEqual(series.projections[1].summary(kind: series.kind, reset: series.current.resetsAt, timeZone: utc),
                       "24 h trend 0.83%/h · reaches 100% Sun 1 Nov 00:00")
        XCTAssertEqual(series.projections[1].label(kind: "5h"), "1 h trend")
        XCTAssertEqual(series.projections[1].label(kind: "Month"), "3 d trend")
        XCTAssertEqual(series.projections[1].label(kind: "Model"), "24 h trend")
    }
}
