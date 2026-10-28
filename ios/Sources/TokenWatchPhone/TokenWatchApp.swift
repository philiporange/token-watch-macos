import SwiftUI

@main
struct TokenWatchPhoneApp: App {
    @StateObject private var store = UsageStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            DashboardView(store: store)
                .preferredColorScheme(.light)
                .tint(Palette.ink)
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    while !Task.isCancelled {
                        await store.refresh()
                        do { try await Task.sleep(for: .seconds(60)) }
                        catch { return }
                    }
                }
        }
    }
}
