import Foundation
import XCTest
@testable import TokenWatchCore

final class ResetNotificationPlanTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_793_155_000)

    func event(_ id: String = "schedule", expected: Date?, kind: ResetKind = .regular, announced: Date? = nil) -> ResetEvent {
        ResetEvent(id: id, kind: kind, announcedAt: announced ?? now.addingTimeInterval(-60), scheduledFor: expected, text: "Reset")
    }

    func testFutureReminderIsStableDeduplicatedAndRetimed() {
        var tracker = ResetTracker()
        let expected = now.addingTimeInterval(3600)
        tracker.apply(ResetStatus(generatedAt: now, scheduled: event(expected: expected), latest: nil), now: now)
        var ledger = ResetNotificationLedger()
        let plan = ResetNotificationPlan.make(tracker: tracker, ledger: ledger, now: now)
        XCTAssertEqual(plan.notices.count, 2)
        XCTAssertEqual(plan.notices.last?.fireAt, expected.addingTimeInterval(-900))
        for notice in plan.notices { ledger.record(notice.id) }
        let again = ResetNotificationPlan.make(tracker: tracker, ledger: ledger, now: now.addingTimeInterval(60))
        XCTAssertTrue(again.notices.isEmpty)
        XCTAssertEqual(again.activeIDs, plan.activeIDs)
        tracker.apply(ResetStatus(generatedAt: now, scheduled: event(expected: expected.addingTimeInterval(3600)), latest: nil), now: now)
        let updated = ResetNotificationPlan.make(tracker: tracker, ledger: ledger, now: now)
        XCTAssertEqual(updated.notices.count, 1)
        XCTAssertFalse(updated.activeIDs.contains(plan.notices.last!.id))
    }

    func testUnknownPastAndNearTimesNeverCreatePastRemindersOrConfirmation() {
        for expected in [nil, now.addingTimeInterval(-60), now.addingTimeInterval(300)] {
            var tracker = ResetTracker()
            tracker.apply(ResetStatus(generatedAt: now, scheduled: event(expected: expected), latest: nil), now: now)
            let plan = ResetNotificationPlan.make(tracker: tracker, ledger: ResetNotificationLedger(), now: now)
            XCTAssertEqual(plan.notices.count, 1)
            XCTAssertTrue(plan.notices[0].id.contains("announced"))
            XCTAssertGreaterThan(plan.notices[0].fireAt, now)
        }
    }

    func testExecutionRemovesReminderAndOldOrBankedEventsDoNotAlert() {
        var tracker = ResetTracker()
        tracker.apply(ResetStatus(generatedAt: now, scheduled: event(expected: now.addingTimeInterval(3600)), latest: nil), now: now)
        let before = ResetNotificationPlan.make(tracker: tracker, ledger: ResetNotificationLedger(), now: now)
        tracker.apply(ResetStatus(generatedAt: now, scheduled: nil,
                                 latest: event("execution", expected: nil, announced: now)), now: now)
        let after = ResetNotificationPlan.make(tracker: tracker, ledger: ResetNotificationLedger(), now: now)
        XCTAssertEqual(after.notices.count, 1)
        XCTAssertTrue(after.notices[0].id.contains("confirmed"))
        XCTAssertTrue(after.activeIDs.isDisjoint(with: before.activeIDs))
        for latest in [event("old", expected: nil, announced: now.addingTimeInterval(-7200)), event("bank", expected: nil, kind: .banked)] {
            var tracker = ResetTracker()
            tracker.apply(ResetStatus(generatedAt: now, scheduled: nil, latest: latest), now: now)
            XCTAssertTrue(ResetNotificationPlan.make(tracker: tracker, ledger: ResetNotificationLedger(), now: now).notices.isEmpty)
        }
    }

    func testLedgerPersistsDeduplicatesAndCanRescheduleCancelledReminder() throws {
        var ledger = ResetNotificationLedger()
        ledger.record("reminder")
        ledger.record("reminder")
        XCTAssertEqual(ledger.issuedIDs, ["reminder"])
        ledger = try JSONDecoder().decode(ResetNotificationLedger.self, from: JSONEncoder().encode(ledger))
        ledger.forget(["reminder"])
        XCTAssertTrue(ledger.issuedIDs.isEmpty)
        for index in 0..<600 { ledger.record(String(index)) }
        XCTAssertEqual(ledger.issuedIDs.count, 512)
    }
}
