import SwiftUI
import TokenWatchCore

struct ProviderDetailView: View {
    let initialProvider: ProviderUsage
    @ObservedObject var store: UsageStore
    @ObservedObject var reminders: BankedResetReminders
    @State private var pendingReset: BankedReset?
    @State private var resultMessages: [String: String] = [:]

    private var provider: ProviderUsage {
        store.snapshot?.providers.first(where: { $0.id == initialProvider.id }) ?? initialProvider
    }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 12) {
                        Eyebrow(text: "Limits", color: .white)
                        Text(provider.provider)
                            .font(.system(size: 38, weight: .bold)).tracking(-1.5)
                            .foregroundStyle(.white)
                        if let detail = provider.detail {
                            Text(detail).font(.system(size: 13)).foregroundStyle(.white)
                        }
                    }
                    VStack(spacing: 24) {
                        limit(provider.fiveHour, title: "Session")
                        Rectangle().fill(.white.opacity(0.25)).frame(height: 1)
                        limit(provider.weekly, title: provider.weekly.title)
                    }
                    .padding(.vertical, 8)

                    if let pace = provider.paceDelta {
                        VStack(alignment: .leading, spacing: 12) {
                            Eyebrow(text: "Pacing", color: .white)
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(abs(pace).formatted(.number.precision(.fractionLength(0))) + "%")
                                    .font(.system(size: 36, weight: .medium)).tracking(-1.5)
                                Text(pace >= 0 ? "under pace" : "over pace")
                                    .font(.system(size: 14))
                            }
                            .foregroundStyle(.white)
                            Text("Remaining allowance compared with time left in the Mac’s pacing window.")
                                .font(.system(size: 12)).foregroundStyle(.white).lineSpacing(4)
                        }
                    }
                    if !provider.modelWindows.isEmpty {
                        VStack(alignment: .leading, spacing: 20) {
                            Eyebrow(text: "Model allowances", color: .white)
                            ForEach(provider.modelWindows) { model in
                                limit(model.window, title: model.modelName)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    if !provider.bankedResets.isEmpty || !resultMessages.isEmpty {
                        bankedResets
                    }
                    if let updated = provider.updatedAt {
                        VStack(alignment: .leading, spacing: 7) {
                            Eyebrow(text: "Last read on your Mac", color: .white)
                            Text(updated.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 12)).foregroundStyle(.white)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.provider(provider.provider).ignoresSafeArea())
            .foregroundStyle(.white)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.font(.system(size: 14, weight: .medium))
                }
            }
            .toolbarBackground(Palette.provider(provider.provider), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .tint(.white)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .task { await reminders.refreshAuthorization() }
        .confirmationDialog("Apply \(provider.provider) reset?", isPresented: Binding(
            get: { pendingReset != nil }, set: { if !$0 { pendingReset = nil } }
        ), titleVisibility: .visible, presenting: pendingReset) { reset in
            Button("Apply Reset", role: .destructive) {
                Task {
                    let result = await store.applyReset(provider: provider, reset: reset)
                    resultMessages[reset.id] = result?.message ?? store.errorMessage ?? "Could not apply this reset."
                }
            }
            Button("Cancel", role: .cancel) { pendingReset = nil }
        } message: { reset in
            Text("\(reset.title) · \(expiryText(reset, now: .now)). This resets current usage windows now and can’t be undone.")
        }
        .presentationDragIndicator(.visible)
        .presentationBackground(Palette.provider(provider.provider))
    }

    private var bankedResets: some View {
        VStack(alignment: .leading, spacing: 18) {
            Eyebrow(text: "Banked resets", color: .white)
            ForEach(provider.bankedResets) { reset in
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(reset.title).font(.system(size: 16, weight: .semibold))
                        Spacer()
                        if store.isApplying(reset, provider: provider) {
                            ProgressView().tint(.white)
                        } else if reset.usable {
                            Button("Apply") { pendingReset = reset }
                                .font(.system(size: 13, weight: .semibold))
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("apply-reset-" + reset.id)
                        }
                    }
                    if let description = reset.description {
                        Text(description).font(.system(size: 12)).lineSpacing(3)
                    }
                    TimelineView(.periodic(from: .now, by: 60)) { timeline in
                        Text(expiryText(reset, now: timeline.date))
                            .font(.system(size: 11, design: .monospaced))
                    }
                    if !reset.usable {
                        Text(reset.status.capitalized).font(.system(size: 12, weight: .medium))
                        if let note = reset.note { Text(note).font(.system(size: 12)).lineSpacing(3) }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("banked-reset-" + reset.id)
                Rectangle().fill(.white.opacity(0.25)).frame(height: 1)
            }
            ForEach(resultMessages.keys.sorted(), id: \.self) { id in
                Text(resultMessages[id] ?? "").font(.system(size: 12)).lineSpacing(3)
                    .accessibilityLabel(resultMessages[id] ?? "")
            }
            Text(store.snapshot?.autoApply?.enabled == true
                 ? "Applied automatically \(store.snapshot?.autoApply?.leadMinutes ?? 5) min before expiry by your Mac"
                 : "Automatic apply is off on your Mac")
                .font(.system(size: 12)).lineSpacing(3)
            Toggle("Remind me before resets expire", isOn: Binding(
                get: { reminders.enabled },
                set: { value in Task { await reminders.setEnabled(value, snapshot: store.snapshot) } }
            ))
            .font(.system(size: 13))
            .tint(.black.opacity(0.4))
            Text("24 h, 12 h, 4 h, 1 h and 15 min before expiry")
                .font(.system(size: 11))
            if reminders.authorization == .denied {
                Text("Notifications are off for Token Watch in Settings.").font(.system(size: 12))
            }
            if let message = reminders.errorMessage { Text(message).font(.system(size: 12)) }
        }
        .foregroundStyle(.white)
    }

    private func expiryText(_ reset: BankedReset, now: Date) -> String {
        guard let expiry = reset.expiresAt else { return "No expiry" }
        let seconds = expiry.timeIntervalSince(now)
        guard seconds > 0 else { return "Expired" }
        if seconds > 86400 { return "Expires " + expiry.formatted(date: .abbreviated, time: .shortened) }
        let minutes = Int(ceil(seconds / 60))
        return "Expires in \(minutes / 60)h \(minutes % 60)m"
    }

    private func limit(_ window: UsageWindow, title: String) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 15, weight: .medium))
                Spacer()
                Text(UsageText.percentage(window.usedPercentage) + (window.usedPercentage == nil ? "" : "%"))
                    .font(.system(size: 30, weight: .medium)).monospacedDigit().tracking(-1)
                    .foregroundStyle(.white)
            }
            UsageTrack(fraction: window.fraction, color: .white)
            if let percentage = window.usedPercentage {
                Text("\(max(0, 100 - percentage).formatted(.number.precision(.fractionLength(0))))% remaining")
                    .font(.system(size: 12)).foregroundStyle(.white)
            }
            if let message = window.message {
                Text(message).font(.system(size: 12)).foregroundStyle(.white).lineSpacing(4)
            }
            if let reset = window.resetsAt {
                Text("Resets " + reset.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white)
            }
        }
    }
}
