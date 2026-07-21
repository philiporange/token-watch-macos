import AppKit
import SwiftUI

// MARK: - Pointing-hand cursor helper

private extension View {
    /// Shows a pointing-hand cursor while the pointer is over the view.
    func pointingHandCursor() -> some View {
        onHover { inside in
            if inside {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

// MARK: - Countdown formatting

/// Formats the time remaining until `date` as "Nd Nh MMm".
///
/// - Below one minute (including past dates) renders "<1m".
/// - The day part appears only when there is at least one day.
/// - The hour part appears when nonzero, or whenever a day part is shown.
/// - Minutes are always rendered as two digits.
private func countdownText(to date: Date, now: Date = Date()) -> String {
    let interval = date.timeIntervalSince(now)
    if interval < 60 {
        return "<1m"
    }
    let totalMinutes = Int(interval / 60)
    let days = totalMinutes / (60 * 24)
    let hours = (totalMinutes % (60 * 24)) / 60
    let minutes = totalMinutes % 60

    var parts: [String] = []
    if days >= 1 {
        parts.append("\(days)d")
    }
    if hours != 0 || days >= 1 {
        parts.append("\(hours)h")
    }
    parts.append(String(format: "%02dm", minutes))
    return parts.joined(separator: " ")
}

// MARK: - MenuContentView

struct MenuContentView: View {
    @ObservedObject var store: UsageStore
    let openSettings: () -> Void
    let popoverHeight: CGFloat

    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.english.rawValue
    @AppStorage("showGeminiOtherModels") private var showGeminiOtherModels = false

    init(store: UsageStore, openSettings: @escaping () -> Void, popoverHeight: CGFloat) {
        self.store = store
        self.openSettings = openSettings
        self.popoverHeight = popoverHeight
    }

    private var loc: Loc {
        Loc(lang: AppLanguage(rawValue: appLanguageRaw) ?? .english)
    }

    var body: some View {
        VStack(spacing: 0) {
            cardStack
            Spacer(minLength: 0)
            footer
        }
        .frame(width: 440)
        .frame(height: popoverHeight, alignment: .top)
        .transaction { $0.animation = nil }
    }

    // MARK: Cards

    private var cardStack: some View {
        VStack(spacing: 10) {
            if store.visibleSnapshots.isEmpty {
                emptyCard
            } else {
                ForEach(store.visibleSnapshots, id: \.provider) { snapshot in
                    ProviderCard(
                        store: store,
                        snapshot: snapshot,
                        showGeminiOtherModels: showGeminiOtherModels,
                        loc: loc
                    )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    private var emptyCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(loc.noAgentsMessage)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(loc.noAgentsHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(loc.openSettings) { openSettings() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointingHandCursor()
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(cardBackground)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.6)
            HStack(spacing: 8) {
                if let lastUpdated = store.lastUpdated {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                        Text(lastUpdated, format: Date.FormatStyle(date: .omitted, time: .shortened))
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .foregroundStyle(.tertiary)
                }

                Spacer()

                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .pointingHandCursor()

                Button {
                    Task { await store.refresh() }
                } label: {
                    HStack(spacing: 4) {
                        if store.isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(loc.refreshAll)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(store.isRefreshing)
                .pointingHandCursor()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - Card background

private var cardBackground: some View {
    RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.primary.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
}

// MARK: - ProviderCard

private struct ProviderCard: View {
    let store: UsageStore
    let snapshot: ProviderSnapshot
    let showGeminiOtherModels: Bool
    let loc: Loc

    private var accent: Color { AppTheme.accent(for: snapshot.provider) }
    private var isRefreshing: Bool { store.refreshingProviders.contains(snapshot.provider) }
    private var lastUpdated: Date? { store.lastUpdatedByProvider[snapshot.provider] }

    private var modelWindows: [ModelUsageWindow] {
        if snapshot.provider == .gemini && !showGeminiOtherModels {
            return []
        }
        return snapshot.modelWindows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            VStack(spacing: 8) {
                ForEach(modelWindows) { model in
                    UsageRowView(accent: accent, loc: loc, model: model, window: model.window)
                }
                UsageRowView(accent: accent, loc: loc, window: snapshot.fiveHour)
                UsageRowView(accent: accent, loc: loc, window: snapshot.weekly)
            }
            .opacity(isRefreshing ? 0.5 : 1)
        }
        .padding(12)
        .background(cardBackground)
    }

    private var header: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(accent.opacity(0.15))
                .frame(width: 26, height: 26)
                .overlay(
                    Text(ProviderDisplayName.displayName(for: snapshot.provider))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(accent)
                )

            Text(snapshot.provider.rawValue)
                .font(.system(size: 15, weight: .semibold))

            if let delta = UsagePacing.delta(for: snapshot.pacingWindow) {
                PaceBadge(delta: delta, loc: loc)
            }

            Spacer(minLength: 8)

            if let detail = snapshot.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let lastUpdated {
                Text(lastUpdated, format: Date.FormatStyle(date: .omitted, time: .shortened))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            refreshControl
        }
    }

    @ViewBuilder
    private var refreshControl: some View {
        if isRefreshing {
            ProgressView()
                .controlSize(.small)
                .frame(width: 22, height: 22)
        } else {
            Button {
                Task { await store.refresh(snapshot.provider) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .frame(width: 22, height: 22)
            .pointingHandCursor()
        }
    }
}

// MARK: - Pace badge

private struct PaceBadge: View {
    let delta: Double
    let loc: Loc

    private var color: Color {
        if delta < -5 {
            return .orange
        } else if delta <= 5 {
            return .green
        } else {
            return .blue
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            PulsingDot(color: color)
            Text(loc.insightMessage(delta: delta))
                .font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.15)))
        .foregroundStyle(color)
    }
}

private struct PulsingDot: View {
    let color: Color
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(pulsing ? 0.35 : 1)
            .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}

// MARK: - Usage row

private struct UsageRowView: View {
    let accent: Color
    let loc: Loc
    var model: ModelUsageWindow? = nil
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                labelView
                Spacer(minLength: 8)
                valueView
                countdownView
            }
            UsageBar(percentage: window.usedPercentage, accent: accent)
        }
    }

    @ViewBuilder
    private var labelView: some View {
        if let model {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(accent)
                Text(model.modelName)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                if model.isActive {
                    Text("ACTIVE")
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(accent.opacity(0.2)))
                        .foregroundStyle(accent)
                }
            }
        } else {
            Text(loc.windowLabel(window.kind))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var valueView: some View {
        if let pct = window.usedPercentage {
            let clamped = max(0, min(100, pct))
            Text("\(Int(clamped.rounded()))%")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
        } else {
            Text(loc.displayMessage(window.message))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var countdownView: some View {
        if let resetsAt = window.resetsAt {
            Text(countdownText(to: resetsAt))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 86, alignment: .trailing)
        }
    }
}

// MARK: - Usage bar

private struct UsageBar: View {
    let percentage: Double?
    let accent: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let clamped = max(0, min(100, percentage ?? 0))
            let fillWidth = clamped > 0 ? max(6, geo.size.width * clamped / 100) : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.85), accent],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillWidth)
                    .opacity(fillOpacity(for: clamped))
            }
        }
        .frame(height: 6)
    }

    private func fillOpacity(for percentage: Double) -> Double {
        guard colorScheme == .dark else { return 1 }
        // Calmer fill at lower percentages in dark mode.
        return 0.7 + 0.3 * (percentage / 100)
    }
}

// MARK: - SettingsView

struct SettingsView: View {
    @ObservedObject var store: UsageStore

    init(store: UsageStore) {
        self.store = store
    }

    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.english.rawValue
    @AppStorage("showGeminiOtherModels") private var showGeminiOtherModels = false

    @AppStorage(MenuBarVisibility.paceRevealEnabledKey) private var paceRevealEnabled = false
    @AppStorage(MenuBarVisibility.paceRevealAboveKey) private var paceRevealAbove = MenuBarVisibility.defaultPaceRevealAbove
    @AppStorage(MenuBarVisibility.paceRevealBelowKey) private var paceRevealBelow = MenuBarVisibility.defaultPaceRevealBelow
    @AppStorage(MenuBarVisibility.resetRevealEnabledKey) private var resetRevealEnabled = false
    @AppStorage(MenuBarVisibility.resetRevealBelowKey) private var resetRevealBelow = MenuBarVisibility.defaultResetRevealBelow
    @AppStorage(MenuBarVisibility.nearingResetRevealEnabledKey) private var nearingResetRevealEnabled = false
    @AppStorage(MenuBarVisibility.nearingResetRevealHoursKey) private var nearingResetRevealHours = MenuBarVisibility.defaultNearingResetRevealHours

    /// Local mirror of each provider's menu-bar tick, since @AppStorage cannot use computed keys.
    @State private var menuBarTicks: [ProviderKind: Bool] = [:]

    private var loc: Loc {
        Loc(lang: AppLanguage(rawValue: appLanguageRaw) ?? .english)
    }

    var body: some View {
        Form {
            generalSection
            agentsSection
            paceRevealSection
            resetRevealSection
            nearingResetRevealSection
        }
        .formStyle(.grouped)
        .onAppear {
            var ticks: [ProviderKind: Bool] = [:]
            for provider in ProviderKind.allCases {
                ticks[provider] = MenuBarVisibility.isTicked(provider)
            }
            menuBarTicks = ticks
        }
    }

    // MARK: General

    private var generalSection: some View {
        Section(loc.general) {
            Picker(loc.language, selection: $appLanguageRaw) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language.rawValue)
                }
            }
            .pickerStyle(.menu)

            VStack(alignment: .leading, spacing: 2) {
                Toggle(loc.launchAtStartup, isOn: Binding(
                    get: { store.launchAtStartupEnabled },
                    set: { store.setLaunchAtStartupEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)

                Text(launchAtStartupDescription)
                    .font(.caption)
                    .foregroundStyle(launchAtStartupDescriptionIsError ? Color.orange : Color.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Picker(loc.autoRefresh, selection: Binding(
                    get: { store.autoRefreshInterval },
                    set: { store.setAutoRefreshInterval($0) }
                )) {
                    ForEach(AutoRefreshInterval.allCases) { interval in
                        Text(loc.refreshLabel(interval)).tag(interval)
                    }
                }
                .pickerStyle(.menu)

                Text(loc.autoRefreshDesc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var launchAtStartupDescriptionIsError: Bool {
        store.launchAtStartupErrorMessage != nil
    }

    private var launchAtStartupDescription: String {
        if let error = store.launchAtStartupErrorMessage {
            return error
        }
        if store.launchAtStartupNeedsApproval {
            return loc.launchAtStartupApprovalDesc
        }
        if !store.launchAtStartupSupported {
            return loc.launchAtStartupUnsupportedDesc
        }
        return loc.launchAtStartupDesc
    }

    // MARK: Agents

    private var agentsSection: some View {
        Section {
            ForEach(ProviderKind.allCases, id: \.self) { provider in
                agentRow(provider)
            }

            VStack(alignment: .leading, spacing: 2) {
                Toggle(loc.geminiOtherModels, isOn: $showGeminiOtherModels)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Text(loc.geminiOtherModelsDesc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(loc.agents)
        } footer: {
            Text(loc.menuBarAgentsDesc)
        }
    }

    private func agentRow(_ provider: ProviderKind) -> some View {
        let status = store.agentStatus(for: provider)
        return HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(AppTheme.accent(for: provider))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.rawValue)
                if let subtitle = agentSubtitle(status) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(loc.statusTitle(status))
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor(status.availability))

            Toggle("", isOn: Binding(
                get: { menuBarTicks[provider] ?? true },
                set: { newValue in
                    menuBarTicks[provider] = newValue
                    UserDefaults.standard.set(newValue, forKey: MenuBarVisibility.defaultsKey(for: provider))
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private func agentSubtitle(_ status: AgentStatus) -> String? {
        if case .error = status.availability {
            return status.message
        }
        return loc.statusInstruction(status)
    }

    private func statusColor(_ availability: AgentAvailability) -> Color {
        switch availability {
        case .available:
            return .green
        case .loading:
            return .secondary
        case .missingAuth, .accessDenied, .sessionExpired, .notInstalled, .notLoggedIn:
            return .orange
        case .error:
            return .red
        }
    }

    // MARK: Reveal rules

    private var paceRevealSection: some View {
        Section {
            Toggle(loc.paceReveal, isOn: $paceRevealEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
            if paceRevealEnabled {
                ThresholdField(label: loc.paceAbove, value: $paceRevealAbove)
                ThresholdField(label: loc.paceBelow, value: $paceRevealBelow)
            }
        } footer: {
            Text(loc.paceRevealDesc)
        }
    }

    private var resetRevealSection: some View {
        Section {
            Toggle(loc.resetReveal, isOn: $resetRevealEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
            if resetRevealEnabled {
                ThresholdField(label: loc.usageBelow, value: $resetRevealBelow)
            }
        } footer: {
            Text(loc.resetRevealDesc)
        }
    }

    private var nearingResetRevealSection: some View {
        Section {
            Toggle(loc.nearingResetReveal, isOn: $nearingResetRevealEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
            if nearingResetRevealEnabled {
                ThresholdField(label: loc.withinHours, value: $nearingResetRevealHours, suffix: "h")
            }
        } footer: {
            Text(loc.nearingResetRevealDesc)
        }
    }
}

// MARK: - Threshold field

private struct ThresholdField: View {
    let label: String
    @Binding var value: Double
    var suffix: String = "%"

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: $value, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .monospaced))
                .frame(width: 64)
            Text(suffix)
                .foregroundStyle(.secondary)
        }
    }
}
