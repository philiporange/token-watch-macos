import SwiftUI
import TokenWatchCore

struct ProviderDetailView: View {
    let provider: ProviderUsage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 12) {
                        Eyebrow(text: "Limits")
                        Text(provider.provider)
                            .font(.system(size: 38, weight: .bold)).tracking(-1.5)
                            .foregroundStyle(Palette.provider(provider.provider))
                        if let detail = provider.detail {
                            Text(detail).font(.system(size: 13)).foregroundStyle(Palette.muted)
                        }
                    }
                    VStack(spacing: 24) {
                        limit(provider.fiveHour, title: "Session")
                        Divider().overlay(Palette.line)
                        limit(provider.weekly, title: provider.weekly.title)
                    }
                    .padding(.vertical, 8)

                    if let pace = provider.paceDelta {
                        VStack(alignment: .leading, spacing: 12) {
                            Eyebrow(text: "Pacing")
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(abs(pace).formatted(.number.precision(.fractionLength(0))) + "%")
                                    .font(.system(size: 36, weight: .medium)).tracking(-1.5)
                                Text(pace >= 0 ? "under pace" : "over pace")
                                    .font(.system(size: 14))
                            }
                            .foregroundStyle(pace >= 0 ? Palette.green : Palette.rust)
                            Text("Remaining allowance compared with time left in the Mac’s pacing window.")
                                .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
                        }
                    }
                    if !provider.modelWindows.isEmpty {
                        VStack(alignment: .leading, spacing: 20) {
                            Eyebrow(text: "Model allowances")
                            ForEach(provider.modelWindows) { model in
                                limit(model.window, title: model.modelName)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    if let updated = provider.updatedAt {
                        VStack(alignment: .leading, spacing: 7) {
                            Eyebrow(text: "Last read on your Mac")
                            Text(updated.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 12)).foregroundStyle(Palette.muted)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.paper.ignoresSafeArea())
            .foregroundStyle(Palette.ink)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.font(.system(size: 14, weight: .medium))
                }
            }
            .toolbarBackground(Palette.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationDragIndicator(.visible)
    }

    private func limit(_ window: UsageWindow, title: String) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 15, weight: .medium))
                Spacer()
                Text(UsageText.percentage(window.usedPercentage) + (window.usedPercentage == nil ? "" : "%"))
                    .font(.system(size: 30, weight: .medium)).monospacedDigit().tracking(-1)
                    .foregroundStyle(Palette.provider(provider.provider))
            }
            UsageTrack(fraction: window.fraction, color: Palette.provider(provider.provider))
            if let percentage = window.usedPercentage {
                Text("\(max(0, 100 - percentage).formatted(.number.precision(.fractionLength(0))))% remaining")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            if let message = window.message {
                Text(message).font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
            }
            if let reset = window.resetsAt {
                Text("Resets " + reset.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
            }
        }
    }
}
