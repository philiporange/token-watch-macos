import Charts
import SwiftUI
import TokenWatchCore

private let historyEmptyText = "History builds up on your Mac: a point every hour, or whenever usage moves by 1%."

struct HistoryRangePicker: View {
    @Binding var selection: UsageHistoryRange
    var ranges: [UsageHistoryRange] = UsageHistoryRange.allCases
    var color: Color = .white

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ranges) { range in
                Button { selection = range } label: {
                    Text(range.label)
                        .font(.system(size: 12, weight: selection == range ? .bold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(selection == range ? color.opacity(0.18) : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("History range \(range.label)")
                .accessibilityAddTraits(selection == range ? .isSelected : [])
                .accessibilityIdentifier("history-range-\(range.rawValue)")
            }
        }
        .foregroundStyle(color)
        .overlay(Rectangle().stroke(color.opacity(0.3), lineWidth: 1))
    }
}

/// A single series, with independently styled projections and a nearest-sample scrubber.
struct UsageHistoryChart: View {
    let series: UsageHistorySeries
    let domain: ClosedRange<Date>
    @State private var selectedDate: Date?

    private var selectedPoint: UsageHistoryPoint? {
        guard let selectedDate else { return nil }
        return series.plottedLine.min { abs($0.t.timeIntervalSince(selectedDate)) < abs($1.t.timeIntervalSince(selectedDate)) }
    }

    private var yMaximum: Double {
        max(100, (series.plottedLine + series.projections.flatMap { $0.clipped(to: domain.upperBound) }).map(\.used).max() ?? 100)
    }

    private var accessibilitySummary: String {
        let reset = series.current.resetsAt.map { "Resets " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "No reset time"
        let projections = series.projections.map { $0.summary(kind: series.kind, reset: series.current.resetsAt) }
        return (["\(series.providerName) \(series.label), current \(UsageText.percentage(series.current.used)) percent", reset]
            + (projections.isEmpty ? [series.noProjectionReason] : projections)).joined(separator: ". ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(series.label).font(.system(size: 16, weight: .semibold))
                Spacer()
                Text(UsageText.percentage(series.current.used) + "%")
                    .font(.system(size: 24, weight: .medium)).monospacedDigit()
            }
            chart
                .frame(height: 200)
                .accessibilityLabel(accessibilitySummary)
                .accessibilityIdentifier("history-chart-\(series.id)")
            if let selectedPoint {
                Text("\(selectedPoint.t.formatted(date: .abbreviated, time: .shortened)) · \(selectedPoint.used.formatted(.number.precision(.fractionLength(0...2))))%")
                    .font(.system(size: 12, design: .monospaced))
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if series.projections.isEmpty {
                Text(series.noProjectionReason).font(.system(size: 12))
            } else {
                ForEach(series.projections, id: \.method) { projection in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            projectionSwatch(projection.method)
                            Text(projection.label(kind: series.kind)).font(.system(size: 11, weight: .semibold))
                        }
                        Text(projection.summary(kind: series.kind, reset: series.current.resetsAt))
                            .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.vertical, 10)
    }

    private func projectionSwatch(_ method: String) -> some View {
        Rectangle()
            .stroke(style: StrokeStyle(lineWidth: 2, dash: method == "trend" ? [2, 3] : [7, 4]))
            .foregroundStyle(method == "trend" ? Palette.reset : .white)
            .frame(width: 26, height: 1)
            .accessibilityHidden(true)
    }

    private var chart: some View {
        Chart {
            ForEach(Array(series.plottedLine.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("Time", point.t), y: .value("Usage", point.used), series: .value("Line", "Usage"))
                    .foregroundStyle(.white)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                PointMark(x: .value("Time", point.t), y: .value("Usage", point.used))
                    .foregroundStyle(.white).symbolSize(14)
            }
            ForEach(series.projections, id: \.method) { projection in
                ForEach(Array(projection.clipped(to: domain.upperBound).enumerated()), id: \.offset) { _, point in
                    LineMark(x: .value("Time", point.t), y: .value("Usage", point.used),
                             series: .value("Line", projection.method))
                        .foregroundStyle(projection.method == "trend" ? Palette.reset : .white.opacity(0.85))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: projection.method == "trend" ? [2, 3] : [7, 4]))
                }
            }
            RuleMark(y: .value("Limit", 100))
                .foregroundStyle(.white.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            if let reset = series.current.resetsAt, domain.contains(reset) {
                RuleMark(x: .value("Reset", reset))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("Reset").font(.system(size: 10)).foregroundStyle(.white)
                    }
            }
            if let point = selectedPoint {
                RuleMark(x: .value("Selected", point.t)).foregroundStyle(.white.opacity(0.6))
                PointMark(x: .value("Selected time", point.t), y: .value("Selected usage", point.used))
                    .foregroundStyle(Palette.reset).symbolSize(50)
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...yMaximum)
        .chartXSelection(value: $selectedDate)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(.white.opacity(0.15))
                AxisValueLabel().foregroundStyle(.white)
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, 50, 100, yMaximum].sorted().reduce(into: [Double]()) { values, value in
                if values.last != value { values.append(value) }
            }) { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.15))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text("\(number.formatted(.number.precision(.fractionLength(0))))%")
                            .foregroundStyle(.white)
                    }
                }
            }
        }
    }
}

/// Shared loading, stale-data and empty states for provider and all-provider history.
struct HistoryContentView: View {
    @ObservedObject var store: UsageStore
    let range: UsageHistoryRange
    var provider: String?
    var grouped = false
    @State private var visibilityID = UUID()

    private var visibleSeries: [UsageHistorySeries] {
        (store.history[range]?.series ?? []).filter { provider == nil || $0.provider == provider }
    }

    private var providerKeys: [String] {
        var seen = Set<String>()
        return visibleSeries.compactMap { seen.insert($0.provider).inserted ? $0.provider : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if store.historyLoading.contains(range) && store.history[range] == nil {
                HStack(spacing: 10) { ProgressView(); Text("Loading history…").font(.system(size: 12)) }
            }
            if let message = store.historyErrors[range] {
                Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            if let history = store.history[range] {
                if store.historyErrors[range] != nil || !store.isReachable {
                    Text("Last updated " + history.generatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11, design: .monospaced))
                }
                if visibleSeries.isEmpty {
                    Text(historyEmptyText).font(.system(size: 13)).lineSpacing(4)
                } else {
                    TimelineView(.periodic(from: .now, by: 60)) { timeline in
                        VStack(alignment: .leading, spacing: 24) {
                            ForEach(providerKeys, id: \.self) { key in
                                VStack(alignment: .leading, spacing: 16) {
                                    if grouped, let name = visibleSeries.first(where: { $0.provider == key })?.providerName {
                                        Eyebrow(text: name, color: .white)
                                    }
                                    ForEach(visibleSeries.filter { $0.provider == key }) { series in
                                        UsageHistoryChart(series: series, domain: history.xDomain(now: timeline.date))
                                    }
                                }
                                .padding(grouped ? 20 : 0)
                                .background(grouped ? Palette.provider(visibleSeries.first(where: { $0.provider == key })?.providerName ?? "") : .clear)
                            }
                        }
                    }
                }
            } else if !store.historyLoading.contains(range) {
                Text("History unavailable").font(.system(size: 16, weight: .semibold))
                Text(historyEmptyText).font(.system(size: 13)).lineSpacing(4)
            }
        }
        .task(id: range) {
            store.showHistory(visibilityID, range: range)
            await store.refreshHistory(range: range)
        }
        .onDisappear { store.hideHistory(visibilityID) }
    }
}

struct UsageHistoryScreen: View {
    @ObservedObject var store: UsageStore
    @Environment(\.dismiss) private var dismiss
    @State private var range: UsageHistoryRange = .week
    @State private var provider = "all"

    private var providers: [(key: String, name: String)] {
        let order = ["claude", "codex", "gemini", "zai", "muse", "alicloud", "commandcode"]
        var names: [String: String] = [:]
        for reading in store.snapshot?.providers ?? [] { names[MacConnection.routeKey(for: reading.provider)] = reading.provider }
        for history in store.history.values {
            for series in history.series { names[series.provider] = series.providerName }
        }
        return order.compactMap { key in names[key].map { (key, $0) } }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HistoryRangePicker(selection: $range, color: Palette.ink)
                    Picker("Provider", selection: $provider) {
                        Text("All providers").tag("all")
                        ForEach(providers, id: \.key) { item in Text(item.name).tag(item.key) }
                    }
                    .tint(Palette.ink)
                    HistoryContentView(store: store, range: range, provider: provider == "all" ? nil : provider, grouped: true)
                }
                .padding(20)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(Palette.ink)
            .background(Palette.paper.ignoresSafeArea())
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .refreshable { await store.refreshHistory(range: range) }
        }
        .presentationDragIndicator(.visible)
    }
}
