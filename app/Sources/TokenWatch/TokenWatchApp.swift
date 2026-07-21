import AppKit
import SwiftUI

@main
struct TokenWatchApp: App {
    @StateObject private var store = UsageStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The Settings window is never shown, so onAppear would never fire;
        // configure during scene evaluation instead.
        let _ = appDelegate.configureIfNeeded(store: store)

        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var optionsWindowController: OptionsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func configureIfNeeded(store: UsageStore) {
        guard statusItemController == nil else { return }

        let openSettings: @MainActor () -> Void = { [weak self] in
            guard let self else { return }

            if self.optionsWindowController == nil {
                self.optionsWindowController = OptionsWindowController(store: store)
            }
            self.optionsWindowController?.show()
        }

        statusItemController = StatusItemController(
            store: store,
            openSettings: openSettings
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
