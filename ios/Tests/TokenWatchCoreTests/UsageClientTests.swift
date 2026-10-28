import Foundation
import XCTest
@testable import TokenWatchCore

final class UsageClientTests: XCTestCase {
    let fixture = Data("""
    {
      "last_updated":"2026-10-28T02:56:17Z",
      "claude": {
        "provider":"Claude",
        "five_hour":{"kind":"5h","used_percentage":0},
        "weekly":{"kind":"Week","used_percentage":23,"resets_at":"2026-10-30T07:59:59.123Z"},
        "model_windows":[{"model_name":"Fable","is_active":false,"window":{"kind":"Model","used_percentage":11}}],
        "pace_delta":45.5,"updated_at":"2026-10-28T02:56:15Z"
      },
      "zai": {
        "provider":"Z.ai",
        "five_hour":{"kind":"5h","message":"No limit returned."},
        "weekly":{"kind":"Month","message":"Sign in on Mac."},
        "model_windows":[]
      }
    }
    """.utf8)

    func testMacResponsePreservesZeroMissingMonthlyAndModelReadings() throws {
        let snapshot = try UsageSnapshot.decode(fixture)
        XCTAssertEqual(snapshot.providers.map(\.provider), ["Claude", "Z.ai"])
        XCTAssertNotNil(snapshot.lastUpdated)
        let claude = snapshot.providers[0]
        XCTAssertEqual(claude.fiveHour.usedPercentage, 0)
        XCTAssertEqual(claude.weekly.fraction, 0.23)
        XCTAssertNotNil(claude.weekly.resetsAt)
        XCTAssertEqual(claude.modelWindows[0].modelName, "Fable")
        XCTAssertFalse(claude.modelWindows[0].isActive)
        XCTAssertEqual(claude.paceDelta, 45.5)
        XCTAssertNil(snapshot.providers[1].weekly.usedPercentage)
        XCTAssertEqual(snapshot.providers[1].weekly.title, "Monthly")
        XCTAssertFalse(snapshot.providers[1].hasReadings)
    }

    func testConnectionNormalizesAddressAndAddsBearerHeader() throws {
        let connection = try MacConnection(address: " sandford.local:8037/usage ", token: " secret-key\n")
        let request = try connection.request()
        XCTAssertEqual(request.url?.absoluteString, "http://sandford.local:8037/usage")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")
        XCTAssertEqual(try MacConnection(address: "mac.local", token: "").address, "http://mac.local:8037")
        XCTAssertEqual(try MacConnection(address: "https://example.com", token: "").address, "https://example.com")
        for bad in ["", "ftp://mac.local", "http://user:pass@mac.local", "http://mac.local/other", "http://mac.local?token=secret", "http://mac.local:0"] {
            XCTAssertThrowsError(try MacConnection(address: bad, token: ""), bad)
        }
    }

    func testAuthAndMalformedResponsesProduceActionableErrors() throws {
        let url = URL(string: "http://mac.local:8037/usage")!
        for code in [401, 403, 500] {
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
            XCTAssertThrowsError(try UsageClient.decode(fixture, response: response)) { error in
                XCTAssertEqual(error as? ConnectionError, code == 500 ? .server(500) : .rejectedKey)
            }
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try UsageClient.decode(Data("{\"status\":\"ok\"}".utf8), response: response))
        XCTAssertEqual(try UsageClient.decode(fixture, response: response).providers.count, 2)
    }

    func testCachedSnapshotCanRoundTripWithoutInventingDatesOrValues() throws {
        let original = try UsageSnapshot.decode(fixture)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
        let restored = try UsageSnapshot.decode(encoder.encode(original))
        XCTAssertEqual(restored, original)
    }
}
