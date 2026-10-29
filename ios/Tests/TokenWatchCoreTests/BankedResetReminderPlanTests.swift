import Foundation
import XCTest
@testable import TokenWatchCore

final class BankedResetReminderPlanTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func provider(_ resets: [BankedReset], name: String = "Codex") throws -> ProviderUsage {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try JSONSerialization.jsonObject(with: encoder.encode(resets))
        let object: [String: Any] = ["provider": name, "five_hour": ["kind": "5h"],
            "weekly": ["kind": "Week"], "model_windows": [], "banked_resets": encoded]
        return try UsageSnapshot.makeDecoder().decode(ProviderUsage.self,
            from: JSONSerialization.data(withJSONObject: object))
    }

    func testAllFiveOffsetsAndDeterministicIdentifiers() throws {
        let expiry = now.addingTimeInterval(2 * 86400)
        let reset = BankedReset(id: "credit_1", title: "Full reset", expiresAt: expiry)
        let plan = BankedResetReminderPlan.make(providers: [try provider([reset], name: "Command Code")], autoApply: nil, now: now)
        XCTAssertEqual(plan.notices.count, 5)
        let offsets = [1440, 720, 240, 60, 15]
        for (notice, minutes) in zip(plan.notices, offsets) {
            XCTAssertEqual(notice.fireAt, expiry.addingTimeInterval(-Double(minutes) * 60))
            XCTAssertEqual(notice.id, "tokenwatch.banked.commandcode.credit_1.\(minutes).\(Int(expiry.timeIntervalSince1970))")
        }
        XCTAssertEqual(plan.activeIDs, Set(plan.notices.map(\.id)))
        XCTAssertEqual(plan.notices.map(\.title), ["24 hours", "12 hours", "4 hours", "1 hour", "15 minutes"]
            .map { "Command Code reset expires in " + $0 })
    }

    func testThreeHoursOnlySchedulesOneHourAndFifteenMinutes() throws {
        let reset = BankedReset(id: "soon", title: "Full reset", expiresAt: now.addingTimeInterval(10800))
        let plan = BankedResetReminderPlan.make(providers: [try provider([reset])], autoApply: nil, now: now)
        XCTAssertEqual(plan.notices.map(\.fireAt), [now.addingTimeInterval(7200), now.addingTimeInterval(9900)])
    }

    func testIneligibleDeadlinesAndConsumedCreditsHaveNoReminders() throws {
        let future = now.addingTimeInterval(172800)
        let resets = [
            BankedReset(id: "past", title: "Past", expiresAt: now.addingTimeInterval(-1)),
            BankedReset(id: "expired", title: "Expired", expiresAt: future, status: "expired"),
            BankedReset(id: "redeemed", title: "Used", expiresAt: future, status: "redeemed"),
            BankedReset(id: "redeeming", title: "Applying", expiresAt: future, status: "redeeming"),
            BankedReset(id: "none", title: "No expiry")
        ]
        let plan = BankedResetReminderPlan.make(providers: [try provider(resets)], autoApply: nil, now: now)
        XCTAssertTrue(plan.notices.isEmpty)
        XCTAssertTrue(plan.activeIDs.isEmpty)
    }

    func testBodyUsesAutoApplyManualOrUnavailableNote() throws {
        let expiry = now.addingTimeInterval(172800)
        let reset = BankedReset(id: "one", title: "Full reset", expiresAt: expiry)
        let providers = [try provider([reset])]
        let automatic = BankedResetReminderPlan.make(providers: providers,
            autoApply: BankedResetAutoApply(enabled: true, leadMinutes: 7), now: now)
        XCTAssertEqual(automatic.notices.first?.body,
            "“Full reset” expires \(expiry.formatted(date: .abbreviated, time: .shortened)). Your Mac will apply it automatically 7 minutes before it expires.")
        for setting in [nil, BankedResetAutoApply(enabled: false, leadMinutes: 5)] {
            let manual = BankedResetReminderPlan.make(providers: providers, autoApply: setting, now: now)
            XCTAssertTrue(try XCTUnwrap(manual.notices.first).body.hasSuffix(" Apply it in Token Watch before then."))
        }
        let unavailable = BankedReset(id: "two", title: "Waiting", expiresAt: expiry,
            status: "unavailable", usable: false, note: "Reach a limit first.")
        let plan = BankedResetReminderPlan.make(providers: [try provider([unavailable])],
            autoApply: BankedResetAutoApply(enabled: true, leadMinutes: 5), now: now)
        XCTAssertTrue(try XCTUnwrap(plan.notices.first).body.hasSuffix(" Reach a limit first."))
        XCTAssertFalse(try XCTUnwrap(plan.notices.first).body.contains("automatically"))
    }

    func testCapUsesEightSoonestExpiriesAcrossProviders() throws {
        let resets = (0..<10).reversed().map { index in
            BankedReset(id: "credit_\(index)", title: "Reset \(index)",
                expiresAt: now.addingTimeInterval(Double(48 + index) * 3600))
        }
        let providers = [try provider(Array(resets.prefix(5)), name: "Claude"),
                         try provider(Array(resets.suffix(5)), name: "Codex")]
        let plan = BankedResetReminderPlan.make(providers: providers, autoApply: nil, now: now)
        XCTAssertEqual(plan.notices.count, 40)
        let creditIDs = plan.notices.enumerated().compactMap { index, notice in
            index.isMultiple(of: 5) ? notice.id.split(separator: ".")[3] : nil
        }
        XCTAssertEqual(creditIDs.map(String.init), (0..<8).map { "credit_\($0)" })
    }

    func testChangedExpiryReplacesIDsAndOneSecondBoundaryIsSkipped() throws {
        let first = BankedReset(id: "one", title: "Reset", expiresAt: now.addingTimeInterval(901))
        XCTAssertTrue(BankedResetReminderPlan.make(providers: [try provider([first])], autoApply: nil, now: now).notices.isEmpty)
        let changed = BankedReset(id: "one", title: "Reset", expiresAt: now.addingTimeInterval(902))
        let plan = BankedResetReminderPlan.make(providers: [try provider([changed])], autoApply: nil, now: now)
        XCTAssertEqual(plan.notices.count, 1)
        XCTAssertEqual(plan.notices.first?.fireAt, now.addingTimeInterval(2))
    }
}
