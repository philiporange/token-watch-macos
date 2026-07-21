import Foundation
import Testing
@testable import TokenWatch

@Suite struct StatusItemControllerTests {

    @Test @MainActor func popoverHeightBuckets() {
        #expect(StatusItemController.popoverHeight(forVisibleSnapshotCount: 0) == 208)
        #expect(StatusItemController.popoverHeight(forVisibleSnapshotCount: 1) == 208)
        #expect(StatusItemController.popoverHeight(forVisibleSnapshotCount: 2) == 348)
        #expect(StatusItemController.popoverHeight(forVisibleSnapshotCount: 3) == 488)
        #expect(StatusItemController.popoverHeight(forVisibleSnapshotCount: 4) == 628)
        #expect(StatusItemController.popoverHeight(forVisibleSnapshotCount: 5) == 628)
    }

    @Test @MainActor func popoverHeightModelWindows() {
        #expect(StatusItemController.popoverHeight(forVisibleSnapshotCount: 2, modelWindowCount: 1) == 388)
    }

    @Test @MainActor func statusItemLength() {
        #expect(StatusItemController.statusItemLength(forContentWidth: 100) == 112)
        #expect(StatusItemController.statusItemLength(forContentWidth: 5) == 32)
        #expect(StatusItemController.statusItemLength(forContentWidth: 20) == 32)
    }
}
