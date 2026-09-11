import Foundation
import Testing
@testable import TokenWatch

@Suite struct StatusItemControllerTests {

    @Test @MainActor func statusItemLength() {
        #expect(StatusItemController.statusItemLength(forContentWidth: 100) == 112)
        #expect(StatusItemController.statusItemLength(forContentWidth: 5) == 32)
        #expect(StatusItemController.statusItemLength(forContentWidth: 20) == 32)
    }
}
