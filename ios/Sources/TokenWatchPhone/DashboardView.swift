import SwiftUI
import TokenWatchCore

private enum UsagePeriod: String, CaseIterable, Identifiable {
    case session = "Session", longRange = "Long range"
    var id: Self { self }
}

struct DashboardView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var resets: CodexResetStore
    @ObservedObject var notifications: ResetNotifications
    @State private var period = UsagePeriod.longRange
    @State private var showsConnection = false
    @State private var selectedProvider: ProviderUsage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                masthead.padding(.horizontal, 24).padding(.top, 12)
                if let snapshot = store.snapshot {
                    sourceStatus(snapshot).padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 12)
                    resetBanner
                    periodPicker.padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 10)
                    if let message = store.errorMessage {
                        notice("\(message) Retrying automatically.").padding(.horizontal, 24).padding(.vertical, 16)
                    }
                    VStack(spacing: 0) {
                        ForEach(snapshot.providers) { provider in
                            Button { selectedProvider = provider } label: {
                                ProviderRow(provider: provider, window: period == .session ? provider.fiveHour : provider.weekly)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("provider-\(provider.id)")
                            .accessibilityHint("Shows all limits and reset times")
                        }
                    }
                    Text("PULL TO REFRESH YOUR MAC")
                        .font(.system(size: 10, design: .monospaced)).tracking(1)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24).padding(.bottom, 44)
                        .background(Palette.provider(snapshot.providers.last?.provider ?? ""))
                } else {
                    resetBanner.padding(.top, 18)
                    welcome.padding(.horizontal, 24).padding(.top, 60).padding(.bottom, 44)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .background(Palette.reset.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .bottom)
        .foregroundStyle(Palette.ink)
        .refreshable { await refreshAll() }
        .sheet(isPresented: $notifications.openDetails, onDismiss: openBankedProvider) {
            ResetDetailsView(store: resets, notifications: notifications)
        }
        .sheet(isPresented: $showsConnection, onDismiss: openBankedProvider) { ConnectionView(store: store) }
        .onChange(of: notifications.openBankedProvider) { _, _ in openBankedProvider() }
        .onChange(of: store.snapshot) { _, _ in openBankedProvider() }
        .onAppear { openBankedProvider() }
        .sheet(item: $selectedProvider) { provider in
            ProviderDetailView(initialProvider: provider, store: store, reminders: store.bankedReminders)
        }
    }

    private func openBankedProvider() {
        guard let route = notifications.openBankedProvider,
              let provider = store.snapshot?.providers.first(where: { MacConnection.routeKey(for: $0.provider) == route }) else { return }
        if notifications.openDetails || showsConnection {
            notifications.openDetails = false
            showsConnection = false
            return
        }
        selectedProvider = provider
        notifications.openBankedProvider = nil
    }

    private var masthead: some View {
        HStack(spacing: 10) {
            Text("Token Watch")
                .font(.system(size: 30, weight: .bold)).tracking(-1.5)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button { notifications.openDetails = true } label: {
                Image(systemName: notifications.enabled && notifications.permitted ? "bell.badge.fill" : "bell")
                    .font(.system(size: 18))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Reset alerts")
            .accessibilityIdentifier("reset-alerts")
            Button { showsConnection = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mac connection")
            .accessibilityValue(store.isReachable ? "Connected" : "Offline")
            .accessibilityIdentifier("connection")
        }
    }

    private func sourceStatus(_ snapshot: UsageSnapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                connectionLabel
                Spacer(minLength: 8)
                updatedLabel(snapshot)
            }
            VStack(alignment: .leading, spacing: 6) {
                connectionLabel
                updatedLabel(snapshot)
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(Palette.muted)
    }

    private var connectionLabel: some View {
        HStack(spacing: 6) {
            Circle().fill(store.isReachable ? Palette.green : Palette.rust).frame(width: 5, height: 5)
            Text(store.isRequestingFreshReadings ? "REFRESHING ON MAC…" : store.isReachable ? (store.connection?.displayName ?? "Mac").uppercased() : store.connection == nil ? "SAVED OFFLINE" : "RECONNECTING…")
                .tracking(0.5)
        }
    }

    @ViewBuilder
    private func updatedLabel(_ snapshot: UsageSnapshot) -> some View {
        if let date = snapshot.lastUpdated {
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                Text("UPDATED " + date.formatted(date: timeline.date.timeIntervalSince(date) > 86400 ? .abbreviated : .omitted, time: .shortened))
                    .foregroundStyle(timeline.date.timeIntervalSince(date) > 900 ? Palette.rust : Palette.muted)
                    .accessibilityLabel("Mac last updated \(date.formatted(date: .abbreviated, time: .shortened))")
            }
        } else {
            Text("NO TIMESTAMP")
        }
    }

    private var periodPicker: some View {
        HStack(spacing: 24) {
            ForEach(UsagePeriod.allCases) { item in
                Button { period = item } label: {
                    VStack(spacing: 10) {
                        Text(item.rawValue)
                            .font(.system(size: 14, weight: period == item ? .semibold : .regular))
                            .foregroundStyle(period == item ? Palette.ink : Palette.muted)
                        Rectangle().fill(period == item ? Palette.ink : .clear).frame(height: 2)
                    }
                    .frame(minHeight: 44)
                    .fixedSize(horizontal: true, vertical: false)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(period == item ? .isSelected : [])
            }
            Spacer(minLength: 0)
            Button { Task { await refreshAll() } } label: {
                Group {
                    if store.isRefreshing { ProgressView().scaleEffect(0.8) }
                    else { Image(systemName: "arrow.clockwise").font(.system(size: 15)) }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .disabled(store.isRefreshing)
            .accessibilityLabel("Refresh readings")
            .accessibilityIdentifier("remote-refresh")
            .accessibilityValue(store.lastRemoteRefresh == nil ? "Not requested" : "Mac refreshed")
        }
    }

    private var resetBanner: some View {
        Button { notifications.openDetails = true } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("CODEX RESET").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 14, weight: .semibold))
                }
                if let event = resets.tracker.upcoming {
                    TimelineView(.periodic(from: .now, by: 30)) { timeline in
                        Text(ResetText.countdown(event.scheduledFor, now: timeline.date))
                            .font(.system(size: 32, weight: .semibold)).tracking(-1)
                    }
                    Text(resets.stale ? "Saved announcement · check for updates" : ResetText.expected(event.scheduledFor))
                        .font(.system(size: 11))
                } else {
                    Text(resets.errorMessage != nil ? "Updates unavailable" : resets.lastChecked == nil ? "Checking announcements" : "No reset scheduled")
                        .font(.system(size: 20, weight: .semibold)).tracking(-0.5)
                }
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.reset)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("codex-reset-banner")
        .overlay(alignment: .bottomTrailing) {
            Link("codex-resets.com ↗", destination: URL(string: "https://codex-resets.com")!)
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.black.opacity(0.65))
                .padding(.trailing, 24).padding(.bottom, 6)
                .accessibilityLabel("Data from Codex Resets")
        }
    }

    private func refreshAll() async {
        async let usage: Void = store.refresh(force: true)
        async let reset: Void = resets.refresh(force: true)
        _ = await (usage, reset)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 24) {
            WatchMark().scaleEffect(1.5, anchor: .leading).padding(.bottom, 20)
            Text("Your Mac’s usage.\nOn your phone.")
                .font(.system(size: 38, weight: .bold)).tracking(-1.7)
            Text(store.connection == nil ? "Connect to Token Watch on the same network." : "Reconnecting to your Mac automatically.")
                .font(.system(size: 15)).foregroundStyle(Palette.muted)
            if let message = store.errorMessage { notice(store.connection == nil ? message : "\(message) Retrying automatically.") }
            if store.isRefreshing {
                HStack(spacing: 12) { ProgressView(); Text("Connecting…").font(.subheadline) }
            }
            if store.connection == nil {
                Button { showsConnection = true } label: {
                    HStack { Text("Connect to Mac"); Spacer(); Image(systemName: "arrow.up.right") }
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.vertical, 20).padding(.horizontal, 18)
                        .foregroundStyle(.white)
                        .background(Palette.accent)
                }
            } else {
                Button("Try connecting now") { Task { await store.refresh() } }
                    .font(.system(size: 15, weight: .semibold))
                    .disabled(store.isRefreshing)
            }
            Text("Provider credentials stay on your Mac.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
    }

    private func notice(_ message: String) -> some View {
        Label(message, systemImage: "wifi.slash")
            .font(.system(size: 12)).lineSpacing(3)
            .foregroundStyle(Palette.rust)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProviderRow: View {
    let provider: ProviderUsage
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(provider.provider)
                    .font(.system(size: 22, weight: .semibold)).tracking(-0.7)
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(UsageText.percentage(window.usedPercentage))
                        .font(.system(size: 42, weight: .medium)).monospacedDigit().tracking(-2)
                    if window.usedPercentage != nil { Text("%").font(.system(size: 17)) }
                }
                .accessibilityLabel(window.usedPercentage.map { "\(UsageText.percentage($0)) percent used" } ?? "Usage unavailable")
            }
            .foregroundStyle(.white)
            UsageTrack(fraction: window.fraction, color: .white)
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                let usable = provider.bankedResets.filter { $0.usable && ($0.expiresAt.map { $0 > timeline.date } ?? true) }
                let resetText = window.usedPercentage == nil ? "Unavailable" : UsageText.reset(window.resetsAt, now: timeline.date)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Text(window.title.uppercased()).tracking(0.7)
                        Spacer(minLength: 0)
                        Text(resetText)
                        if !usable.isEmpty { Text(resetSummary(usable, now: timeline.date)) }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(window.title.uppercased()).tracking(0.7)
                            Spacer()
                            Text(resetText)
                        }
                        if !usable.isEmpty {
                            Text(resetSummary(usable, now: timeline.date))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
        .background(Palette.provider(provider.provider))
        .accessibilityElement(children: .combine)
    }

    private func resetSummary(_ resets: [BankedReset], now: Date) -> String {
        let count = "\(resets.count) " + (resets.count == 1 ? "RESET" : "RESETS")
        guard let expiry = resets.compactMap(\.expiresAt).min() else { return count }
        let hours = max(1, Int(ceil(expiry.timeIntervalSince(now) / 3600)))
        return count + " · NEXT EXPIRES IN \(hours)H"
    }
}
