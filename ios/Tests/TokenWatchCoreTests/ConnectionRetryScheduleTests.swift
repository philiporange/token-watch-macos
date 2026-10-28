import XCTest
@testable import TokenWatchCore

final class ConnectionRetryScheduleTests: XCTestCase {
    func testBoundedRetriesAndRecovery() {
        var schedule = ConnectionRetrySchedule()
        XCTAssertEqual(schedule.nextDelay, 60)
        for expected in [5.0, 10.0, 20.0, 30.0, 30.0] {
            schedule.recordFailure()
            XCTAssertEqual(schedule.nextDelay, expected)
        }
        schedule.recordSuccess()
        XCTAssertEqual(schedule.failures, 0)
        XCTAssertEqual(schedule.nextDelay, 60)
        schedule.recordFailure()
        XCTAssertEqual(schedule.nextDelay, 5)
    }
}
