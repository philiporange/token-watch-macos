import AppKit
import SwiftUI

@MainActor
final class UsageHistoryWindowController: NSWindowController {
    private let store: UsageStore

    init(store: UsageStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 520)
        super.init(window: window)
        shouldCascadeWindows = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        guard let window else { return }
        let language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "en") ?? .english
        window.title = Loc(lang: language).usageHistory
        window.contentViewController = NSHostingController(rootView: UsageHistoryView(store: store))
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
