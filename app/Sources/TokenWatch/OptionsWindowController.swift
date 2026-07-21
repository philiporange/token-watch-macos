import AppKit
import SwiftUI

@MainActor
final class OptionsWindowController: NSWindowController {
    init(store: UsageStore) {
        let settingsView = SettingsView(store: store)
            .frame(width: 520)
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Options"
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        window.minSize = NSSize(width: 520, height: 460)

        super.init(window: window)

        self.shouldCascadeWindows = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }

        let preferredHeight: CGFloat = 640
        let minHeight: CGFloat = 460
        let width: CGFloat = 520
        let slack: CGFloat = 120

        let screenHeight = NSScreen.main?.visibleFrame.height ?? (preferredHeight + slack)
        let maxAllowedHeight = screenHeight - slack
        let resolvedHeight = max(minHeight, min(preferredHeight, maxAllowedHeight))

        let wasVisible = window.isVisible

        window.setContentSize(NSSize(width: width, height: resolvedHeight))

        if !wasVisible {
            window.center()
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
