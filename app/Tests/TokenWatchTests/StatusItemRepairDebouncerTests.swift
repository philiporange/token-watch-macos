import Foundation
import Testing
@testable import TokenWatch

@MainActor
private final class RepairRecorder {
    var reasons: [StatusItemRepairReason] = []
}

@Suite @MainActor struct StatusItemRepairDebouncerTests {

    @Test func scheduleFiresWithReasonAfterDelay() async {
        let recorder = RepairRecorder()
        let debouncer = StatusItemRepairDebouncer(delay: .milliseconds(50)) { reason in
            recorder.reasons.append(reason)
        }
        debouncer.schedule(reason: .wake)

        try? await Task.sleep(for: .milliseconds(200))
        #expect(recorder.reasons == [.wake])
    }

    @Test func rapidReschedulesCoalesce() async {
        let recorder = RepairRecorder()
        let debouncer = StatusItemRepairDebouncer(delay: .milliseconds(80)) { reason in
            recorder.reasons.append(reason)
        }
        debouncer.schedule(reason: .wake)
        debouncer.schedule(reason: .displayChange)
        debouncer.schedule(reason: .wakeFollowup)

        try? await Task.sleep(for: .milliseconds(250))
        #expect(recorder.reasons == [.wakeFollowup])
    }

    @Test func cancelPreventsInvocation() async {
        let recorder = RepairRecorder()
        let debouncer = StatusItemRepairDebouncer(delay: .milliseconds(50)) { reason in
            recorder.reasons.append(reason)
        }
        debouncer.schedule(reason: .wake)
        debouncer.cancel()

        try? await Task.sleep(for: .milliseconds(200))
        #expect(recorder.reasons.isEmpty)
    }
}
