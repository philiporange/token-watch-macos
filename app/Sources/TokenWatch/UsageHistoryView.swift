import SwiftUI
import Charts

struct UsageHistoryView: View {
    @ObservedObject var store: UsageStore
    @AppStorage("appLanguage") private var language = AppLanguage.english.rawValue
    @State private var range: UsageHistoryRange = .week
    @State private var provider: String = ""
    @State private var response: UsageHistoryResponse?
    @State private var availableProviders: [ProviderKind] = []

    private var loc: Loc { Loc(lang: AppLanguage(rawValue: language) ?? .english) }
    private var reloadID: String { "\(range.rawValue)/\(provider)/\(store.historyRevision)" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                Picker(loc.historyRange, selection: $range) {
                    ForEach(UsageHistoryRange.allCases, id: \.self) { range in
                        Text(loc.historyRangeLabel(range)).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                Picker(loc.historyProvider, selection: $provider) {
                    Text(loc.historyAll).tag("")
                    ForEach(availableProviders, id: \.self) { provider in
                        Text(provider.rawValue).tag(provider.routeKey)
                    }
                }
                .frame(width: 200)
            }
            .padding()
            Divider()
            if store.historyError != nil {
                Text(loc.historyUnavailable).foregroundStyle(.secondary).padding()
            }
            if let response {
                if response.series.isEmpty {
                    ContentUnavailableView {
                        Label(loc.usageHistory, systemImage: "chart.xyaxis.line")
                    } description: {
                        Text(loc.historyEmpty)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(response.series) { series in
                                UsageHistoryCard(series: series, response: response, loc: loc)
                            }
                        }
                        .padding()
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .task(id: reloadID) {
            // A full refresh bumps the revision once per provider; reload once the burst settles.
            if response != nil {
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            }
            availableProviders = await store.historyProviders()
            guard !Task.isCancelled else { return }
            let result = await store.history(range: range, provider: ProviderKind.from(routeKey: provider))
            guard !Task.isCancelled else { return }
            response = result
        }
    }
}

/// Chart domain and clipped projection endpoints follow the shared dashboard display rule.
enum UsageHistoryChart {
    static func points(_ series: UsageHistorySeries) -> [UsageHistoryPoint] {
        if let last = series.points.last, series.current.t <= last.t { return series.points }
        return series.points + [series.current]
    }
    static func domain(series: UsageHistorySeries, response: UsageHistoryResponse) -> ClosedRange<Date> {
        let start = response.since ?? points(series).first?.t ?? series.current.t
        let span = max(1, response.generatedAt.timeIntervalSince(start))
        return start...max(start.addingTimeInterval(1), response.generatedAt.addingTimeInterval(span * 0.25))
    }
    static func clipped(_ projection: UsageHistoryProjection, end: Date) -> UsageHistoryCoordinate {
        guard projection.to.t > end, projection.to.t > projection.from.t else { return projection.to }
        let fraction = max(0, end.timeIntervalSince(projection.from.t) / projection.to.t.timeIntervalSince(projection.from.t))
        return .init(t: end, used: projection.from.used + fraction * (projection.to.used - projection.from.used))
    }
}

private struct UsageHistoryCard: View {
    let series: UsageHistorySeries
    let response: UsageHistoryResponse
    let loc: Loc
    @State private var hover: UsageHistoryPoint?

    private var accent: Color { AppTheme.accent(for: ProviderKind.from(routeKey: series.provider) ?? .claude) }
    private var domain: ClosedRange<Date> { UsageHistoryChart.domain(series: series, response: response) }
    private var points: [UsageHistoryPoint] { UsageHistoryChart.points(series) }
    private var locale: Locale { Locale(identifier: loc.lang.rawValue) }
    private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1)).locale(locale)) }
    private func date(_ value: Date) -> String { value.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute().locale(locale)) }
    private func method(_ projection: UsageHistoryProjection) -> String { projection.method == "average" ? loc.historyAverage : loc.historyTrend(kind: series.kind) }
    private func stroke(_ projection: UsageHistoryProjection) -> StrokeStyle {
        StrokeStyle(lineWidth: 2, dash: projection.method == "average" ? [7, 4] : [2, 4])
    }
    private func projectionColor(_ projection: UsageHistoryProjection) -> Color { projection.method == "average" ? accent : .secondary }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(series.providerName + " · " + loc.historyLabel(series)).font(.headline).foregroundStyle(accent)
                Spacer()
                Text(number(series.current.used) + "%").font(.title2.monospacedDigit())
                if let reset = series.current.resetsAt {
                    Text(loc.historyReset + " " + date(reset)).font(.caption).foregroundStyle(.secondary)
                }
            }
            chart.frame(height: 220)
            HStack(spacing: 18) {
                ForEach(series.projections, id: \.method) { projection in
                    HStack(spacing: 6) {
                        Path { p in p.move(to: .init(x: 0, y: 4)); p.addLine(to: .init(x: 26, y: 4)) }
                            .stroke(projectionColor(projection), style: stroke(projection)).frame(width: 26, height: 8)
                        Text(method(projection))
                    }
                }
            }
            .font(.caption)
            Text(hover.map { date($0.t) + " · " + number($0.used) + "%" } ?? " ")
                .font(.caption.monospacedDigit())
            if series.projections.isEmpty {
                Text(series.current.resetsAt == nil ? loc.historyNoReset : loc.historyNotEnough)
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(series.projections, id: \.method) { projection in
                Text(method(projection) + " " + loc.historyProjection(rate: number(projection.ratePerHour),
                    value: number(projection.atReset), date: date(projection.limitAt ?? series.current.resetsAt ?? projection.to.t),
                    reachesLimit: projection.limitAt != nil))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var chart: some View {
        Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value(loc.historyTime, point.t), y: .value(loc.historyValue, point.used), series: .value(loc.usage, "usage"))
                    .foregroundStyle(accent)
                PointMark(x: .value(loc.historyTime, point.t), y: .value(loc.historyValue, point.used))
                    .foregroundStyle(accent).symbolSize(18)
            }
            RuleMark(y: .value(loc.historyLimit, 100)).foregroundStyle(.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            if let reset = series.current.resetsAt, domain.contains(reset) {
                RuleMark(x: .value(loc.historyReset, reset)).foregroundStyle(.secondary.opacity(0.5))
                    .annotation(position: .top, alignment: .trailing) { Text(loc.historyReset).font(.caption2) }
            }
            ForEach(series.projections, id: \.method) { projection in
                let end = UsageHistoryChart.clipped(projection, end: domain.upperBound)
                ForEach(Array([projection.from, end].enumerated()), id: \.offset) { _, point in
                    LineMark(x: .value(loc.historyTime, point.t), y: .value(loc.historyValue, point.used), series: .value(loc.usage, projection.method))
                        .foregroundStyle(projectionColor(projection)).lineStyle(stroke(projection))
                }
            }
            if let hover {
                RuleMark(x: .value(loc.historyTime, hover.t)).foregroundStyle(.secondary.opacity(0.3))
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...max(100, points.map(\.used).max() ?? 100))
        .chartYAxis { AxisMarks { value in
            AxisGridLine()
            AxisValueLabel { if let percent = value.as(Double.self) { Text(number(percent) + "%") } }
        } }
        .chartPlotStyle { $0.clipped() }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let frame = proxy.plotFrame else { return }
                            let plot = geometry[frame]
                            guard plot.contains(location), let time: Date = proxy.value(atX: location.x - plot.minX) else { hover = nil; return }
                            hover = points.min { abs($0.t.timeIntervalSince(time)) < abs($1.t.timeIntervalSince(time)) }
                        case .ended: hover = nil
                        }
                    }
            }
        }
    }
}
