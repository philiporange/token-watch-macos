import SwiftUI
import TokenWatchCore

enum ResetText {
    static func countdown(_ date: Date?, now: Date) -> String {
        guard let date else { return "Time to be announced" }
        let minutes = Int(ceil(date.timeIntervalSince(now) / 60))
        guard minutes > 0 else { return "Awaiting confirmation" }
        let hours = minutes / 60
        return hours > 0 ? "Within ~\(hours)h \(minutes % 60)m" : "Within ~\(minutes)m"
    }

    static func expected(_ date: Date?) -> String {
        guard let date else { return "Announced · no time confirmed" }
        if date <= .now { return "Expected time passed · still pending" }
        return "Expected by " + date.formatted(date: .omitted, time: .shortened)
    }
}

struct ResetDetailsView: View {
    @ObservedObject var store: CodexResetStore
    @ObservedObject var notifications: ResetNotifications
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("Codex resets")
                        .font(.system(size: 34, weight: .bold)).tracking(-1.5)
                    status
                    if let message = store.errorMessage {
                        Text(message).font(.system(size: 12)).foregroundStyle(Palette.rust)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Eyebrow(text: "Reset alerts")
                        if notifications.enabled && notifications.permitted {
                            Label("Alerts on", systemImage: "bell.badge.fill")
                                .font(.system(size: 20, weight: .semibold)).foregroundStyle(Palette.accent)
                                .accessibilityIdentifier("alerts-enabled")
                            Text("\(notifications.reminderCount) upcoming reminder\(notifications.reminderCount == 1 ? "" : "s") scheduled")
                                .font(.system(size: 13)).foregroundStyle(Palette.muted)
                            HStack(spacing: 22) {
                                Button(notifications.testSent ? "Test sent" : "Send test alert") {
                                    Task { await notifications.sendTest() }
                                }
                                .accessibilityIdentifier("test-reset-notification")
                                Button("Turn off") {
                                    Task {
                                        await notifications.disable()
                                        store.scheduleBackgroundRefresh()
                                    }
                                }
                            }
                            .font(.system(size: 13, weight: .medium)).frame(minHeight: 44)
                        } else if notifications.authorization == .denied {
                            Text("Notifications are off in iOS Settings.")
                                .font(.system(size: 14)).foregroundStyle(Palette.muted)
                            Button("Open iOS Settings") {
                                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                            }
                            .frame(minHeight: 44).foregroundStyle(Palette.accent)
                        } else {
                            Button {
                                Task { await store.enableNotifications() }
                            } label: {
                                HStack {
                                    Text("Enable notifications")
                                    Spacer()
                                    Image(systemName: "bell.badge")
                                }
                                .font(.system(size: 15, weight: .semibold))
                                .padding(18).foregroundStyle(.white).background(Palette.accent)
                            }
                            .accessibilityIdentifier("enable-reset-notifications")
                        }
                        Text("Get new reset announcements, a reminder 15 minutes before the expected time, and confirmation when a reset is reported.")
                            .font(.system(size: 13)).foregroundStyle(Palette.muted).lineSpacing(4)
                        Text("Scheduled reminders work while the app is closed. New announcements are checked when you open the app and when iOS allows background refresh.")
                            .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
                        if store.backgroundUnavailable {
                            Text("Background refresh is unavailable. Scheduled reminders still work; open the app to check new announcements.")
                                .font(.system(size: 12)).foregroundStyle(Palette.rust)
                        }
                        if let message = notifications.errorMessage {
                            Text(message).font(.system(size: 12)).foregroundStyle(Palette.rust)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        if let latest = store.tracker.latest {
                            Eyebrow(text: latest.kind == .banked ? "Last banked credit reported" : "Last reset reported")
                            Text(latest.announcedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 16, weight: .medium))
                        }
                        if let checked = store.lastChecked {
                            Text("Checked " + checked.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                        }
                        Link("Data from codex-resets.com ↗", destination: URL(string: "https://codex-resets.com")!)
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.accent)
                        Text("Announcement timing is an estimate. Execution reports are separate from your account’s normal weekly reset and balance.")
                            .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
                    }
                }
                .padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }
            .background(Palette.paper.ignoresSafeArea())
            .foregroundStyle(Palette.ink)
            .refreshable { await store.refresh(force: true) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .toolbarBackground(Palette.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationDragIndicator(.visible)
        .task { await notifications.refreshAuthorization() }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let event = store.tracker.upcoming {
                Eyebrow(text: "Announced reset")
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    Text(ResetText.countdown(event.scheduledFor, now: timeline.date))
                        .font(.system(size: 28, weight: .semibold)).tracking(-1)
                }
                if let expected = event.scheduledFor {
                    Text("Expected by " + expected.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 13))
                }
                if let source = event.sourceURL {
                    Link("View announcement ↗", destination: source).font(.system(size: 12, weight: .medium))
                }
                if store.stale { Text("Saved announcement · refresh to check").font(.caption) }
            } else {
                Text(store.errorMessage == nil ? "No reset scheduled" : "Updates unavailable")
                    .font(.system(size: 23, weight: .semibold))
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Palette.reset)
    }
}
