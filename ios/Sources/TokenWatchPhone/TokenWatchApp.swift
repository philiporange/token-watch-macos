import SwiftUI

@main
struct TokenWatchPhoneApp: App {
    @StateObject private var store = UsageStore()
    @StateObject private var resets: CodexResetStore
    @StateObject private var notifications: ResetNotifications
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let alerts = ResetNotifications()
        _notifications = StateObject(wrappedValue: alerts)
        _resets = StateObject(wrappedValue: CodexResetStore(notifications: alerts))
    }

    var body: some Scene {
        WindowGroup {
            DashboardView(store: store, resets: resets, notifications: notifications)
                .preferredColorScheme(.light)
                .tint(Palette.ink)
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    store.startMonitoring()
                    await notifications.refreshAuthorization()
                    while !Task.isCancelled {
                        async let usage: Void = store.refresh()
                        async let reset: Void = resets.refresh()
                        _ = await (usage, reset)
                        do { try await Task.sleep(for: .seconds(store.automaticRefreshDelay)) }
                        catch { return }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { store.stopMonitoring() }
                    if phase == .background {
                        resets.scheduleBackgroundRefresh(hasConnection: store.connection != nil)
                    }
                }
        }
        .backgroundTask(.appRefresh(CodexResetStore.backgroundIdentifier)) {
            async let usage: Void = store.refresh()
            async let reset: Void = resets.refresh()
            _ = await (usage, reset)
            await resets.scheduleBackgroundRefresh(hasConnection: store.connection != nil)
        }
    }
}
