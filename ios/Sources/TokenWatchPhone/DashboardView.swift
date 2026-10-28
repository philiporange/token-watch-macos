import SwiftUI
import TokenWatchCore

private enum UsagePeriod: String, CaseIterable, Identifiable {
    case session = "Session", longRange = "Long range"
    var id: Self { self }
}

struct DashboardView: View {
    @ObservedObject var store: UsageStore
    @State private var period = UsagePeriod.longRange
    @State private var showsConnection = false
    @State private var selectedProvider: ProviderUsage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                masthead
                if let snapshot = store.snapshot {
                    sourceStatus(snapshot).padding(.top, 4).padding(.bottom, 26)
                    periodPicker.padding(.bottom, 6)
                    if let message = store.errorMessage {
                        notice(message).padding(.vertical, 16)
                    }
                    ForEach(snapshot.providers) { provider in
                        Button { selectedProvider = provider } label: {
                            ProviderRow(provider: provider, window: period == .session ? provider.fiveHour : provider.weekly)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("provider-\(provider.id)")
                        .accessibilityHint("Shows all limits and reset times")
                    }
                    Text("PULL TO REFRESH")
                        .font(.system(size: 10, design: .monospaced)).tracking(1)
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 28)
                } else {
                    welcome.padding(.top, 60)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 32)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.paper.ignoresSafeArea())
        .foregroundStyle(Palette.ink)
        .refreshable { await store.refresh() }
        .sheet(isPresented: $showsConnection) { ConnectionView(store: store) }
        .sheet(item: $selectedProvider) { provider in
            ProviderDetailView(provider: store.snapshot?.providers.first(where: { $0.id == provider.id }) ?? provider)
        }
    }

    private var masthead: some View {
        HStack(spacing: 10) {
            Text("Token Watch")
                .font(.system(size: 30, weight: .bold)).tracking(-1.5)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button { showsConnection = true } label: {
                Image(systemName: "slider.horizontal.3")
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
            Text(store.isReachable ? (store.connection?.displayName ?? "Mac").uppercased() : "SAVED OFFLINE")
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
            Button { Task { await store.refresh() } } label: {
                Group {
                    if store.isRefreshing { ProgressView().scaleEffect(0.8) }
                    else { Image(systemName: "arrow.clockwise").font(.system(size: 15)) }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .disabled(store.isRefreshing)
            .accessibilityLabel("Refresh readings")
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 24) {
            WatchMark().scaleEffect(1.5, anchor: .leading).padding(.bottom, 20)
            Text("Your Mac’s usage.\nOn your phone.")
                .font(.system(size: 38, weight: .bold)).tracking(-1.7)
            Text("Connect to Token Watch on the same network.")
                .font(.system(size: 15)).foregroundStyle(Palette.muted)
            if let message = store.errorMessage { notice(message) }
            if store.isRefreshing {
                HStack(spacing: 12) { ProgressView(); Text("Connecting…").font(.subheadline) }
            }
            Button { showsConnection = true } label: {
                HStack { Text("Connect to Mac"); Spacer(); Image(systemName: "arrow.up.right") }
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.vertical, 20).padding(.horizontal, 18)
                    .foregroundStyle(.white)
                    .background(Palette.accent)
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
            .foregroundStyle(Palette.provider(provider.provider))
            UsageTrack(fraction: window.fraction, color: Palette.provider(provider.provider))
            HStack {
                Text(window.title.uppercased()).tracking(0.7)
                Spacer()
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    Text(window.usedPercentage == nil ? "Unavailable" : UsageText.reset(window.resetsAt, now: timeline.date))
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Palette.muted)
        }
        .padding(.vertical, 19)
        .accessibilityElement(children: .combine)
    }
}
