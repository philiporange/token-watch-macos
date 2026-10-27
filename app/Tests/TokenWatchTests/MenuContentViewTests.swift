import AppKit
import SwiftUI
import Testing
@testable import TokenWatch

@Suite @MainActor struct MenuContentViewTests {
    @Test func providerTimestampRedrawsWhenUsageIsUnchanged() async throws {
        let suite = "provider-timestamp-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(
            claudeProbe: ProbeStub(queue: ProbeQueue([makeSnapshot(.claude)])),
            codexProbe: ProbeStub(queue: ProbeQueue([makeSnapshot(.codex, weeklyUsed: 6)])),
            userDefaults: defaults,
            startRefreshLoop: false
        )
        store.codex = makeSnapshot(.codex, weeklyUsed: 6)
        let earlier = Date(timeIntervalSince1970: 1_793_091_600)
        store.lastUpdatedByProvider[.codex] = earlier

        let view = NSHostingView(rootView: MenuContentView(store: store, openSettings: {}))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 858, height: 900),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        defer { window.contentView = nil }
        try await Task.sleep(for: .milliseconds(150))
        let before = try pixels(in: view)

        store.lastUpdatedByProvider[.codex] = earlier.addingTimeInterval(10)
        try await Task.sleep(for: .milliseconds(150))
        let after = try pixels(in: view)

        #expect(store.codex.weekly.usedPercentage == 6)
        #expect(before != after, "The provider card must redraw its timestamp even when its usage snapshot is identical.")
    }

    private func pixels(in view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let bytes = try #require(bitmap.bitmapData)
        return Data(bytes: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }
}
