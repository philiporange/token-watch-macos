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
        let refresh = try connection.request(refresh: true)
        XCTAssertEqual(refresh.url?.absoluteString, "http://sandford.local:8037/refresh")
        XCTAssertEqual(refresh.httpMethod, "POST")
        XCTAssertEqual(refresh.value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")
        XCTAssertEqual(refresh.timeoutInterval, 60)
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

    private func bankedFixture() throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        var claude = try XCTUnwrap(object["claude"] as? [String: Any])
        claude["banked_resets"] = [[
            "id": "credit_123", "title": "Full reset", "description": "Refills limits",
            "granted_at": "2026-10-28T12:00:00.123Z", "expires_at": "2026-10-30T12:00:00Z",
            "status": "available", "usable": true, "remaining": 1, "note": NSNull()
        ]]
        object["claude"] = claude
        object["banked_reset_auto_apply"] = ["enabled": true, "lead_minutes": 5]
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testBankedResetsDecodeAndRoundTripWithAutoApply() throws {
        let snapshot = try UsageSnapshot.decode(bankedFixture())
        let reset = try XCTUnwrap(snapshot.providers[0].bankedResets.first)
        XCTAssertEqual(reset.id, "credit_123")
        XCTAssertEqual(reset.title, "Full reset")
        XCTAssertEqual(reset.description, "Refills limits")
        XCTAssertNotNil(reset.expiresAt)
        XCTAssertNotNil(reset.grantedAt)
        XCTAssertEqual(reset.status, "available")
        XCTAssertTrue(reset.usable)
        XCTAssertEqual(reset.remaining, 1)
        XCTAssertEqual(snapshot.autoApply, BankedResetAutoApply(enabled: true, leadMinutes: 5))
        XCTAssertEqual(snapshot.providers[1].bankedResets, [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
        XCTAssertEqual(try UsageSnapshot.decode(encoder.encode(snapshot)), snapshot)
        let old = try UsageSnapshot.decode(fixture)
        XCTAssertNil(old.autoApply)
        XCTAssertTrue(old.providers.allSatisfy { $0.bankedResets.isEmpty })
    }

    func testApplyUsageReplacesOnlyItsProviderAndPreservesSnapshotMetadata() throws {
        let snapshot = try UsageSnapshot.decode(bankedFixture())
        let older = try UsageSnapshot.decode(fixture)
        let updated = snapshot.replacingProvider(older.providers[0])
        XCTAssertEqual(updated.providers[0], older.providers[0])
        XCTAssertEqual(updated.providers[1], snapshot.providers[1])
        XCTAssertEqual(updated.lastUpdated, snapshot.lastUpdated)
        XCTAssertEqual(updated.autoApply, snapshot.autoApply)
    }

    func testBankedResetInvalidIDsAreSkipped() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bankedFixture()) as? [String: Any])
        var claude = try XCTUnwrap(object["claude"] as? [String: Any])
        var resets = try XCTUnwrap(claude["banked_resets"] as? [[String: Any]])
        for badID in ["invalid/id", "trailing\n", "", String(repeating: "a", count: 129)] {
            var invalid = resets[0]
            invalid["id"] = badID
            resets.append(invalid)
        }
        claude["banked_resets"] = resets
        object["claude"] = claude
        XCTAssertEqual(try UsageSnapshot.decode(JSONSerialization.data(withJSONObject: object))
            .providers[0].bankedResets.map(\.id), ["credit_123"])
    }

    func testApplyRequestEncodesOnePathSegmentAndUsesPairedPost() throws {
        let connection = try MacConnection(address: "mac.local:8037", token: "test-key")
        let request = try connection.applyResetRequest(providerRouteKey: "codex", resetID: "a/b ?#%")
        XCTAssertEqual(request.url?.absoluteString, "http://mac.local:8037/resets/codex/a%2Fb%20%3F%23%25/apply")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.httpBody, Data())
        XCTAssertEqual(request.timeoutInterval, 60)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(MacConnection.routeKey(for: "Z.ai"), "zai")
        XCTAssertEqual(MacConnection.routeKey(for: "Command Code"), "commandcode")
    }

    func testApplyResultsDecodeAnsweredStatusesAndRejectAuthentication() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bankedFixture()) as? [String: Any])
        let url = URL(string: "http://mac.local:8037/resets/claude/credit_123/apply")!
        for (code, outcome, applied) in [(200, "reset", true), (404, "not_found", false),
                                          (409, "not_usable", false), (502, "unconfirmed", false)] {
            let payload: [String: Any] = ["provider": "claude", "reset_id": "credit_123", "outcome": outcome,
                "applied": applied, "message": "Result: " + outcome, "usage": object["claude"]!]
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
            let result = try UsageClient.decodeApplyResult(JSONSerialization.data(withJSONObject: payload), response: response)
            XCTAssertEqual(result.outcome, outcome)
            XCTAssertEqual(result.applied, applied)
            XCTAssertEqual(result.resetID, "credit_123")
            XCTAssertEqual(result.message, "Result: " + outcome)
            XCTAssertEqual(result.usage.provider, "Claude")
            XCTAssertEqual(result.usage.bankedResets.count, 1)
        }
        for code in [401, 403, 500] {
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
            XCTAssertThrowsError(try UsageClient.decodeApplyResult(Data(), response: response)) {
                XCTAssertEqual($0 as? ConnectionError, code == 500 ? .server(500) : .rejectedKey)
            }
        }
    }

}
