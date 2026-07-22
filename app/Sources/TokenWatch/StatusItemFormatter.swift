import Foundation

struct StatusItemMetric: Identifiable, Equatable {
    let label: String
    let value: String
    let isModelScoped: Bool

    var id: String {
        "\(label)-\(isModelScoped)"
    }
}

struct StatusItemProviderUsage: Equatable {
    let name: String
    let metrics: [StatusItemMetric]
}

enum StatusItemFormatter {

    static func compactValue(for window: UsageWindow) -> String {
        guard let percentage = window.usedPercentage else {
            return "--"
        }
        return String(format: "%.0f", percentage.rounded())
    }

    static func content(name: String, snapshot: ProviderSnapshot) -> StatusItemProviderUsage {
        var metrics: [StatusItemMetric] = []

        // 1. Model-scoped metrics (one per model window)
        for modelWindow in snapshot.modelWindows {
            let label = truncatedModelName(from: modelWindow.modelName)
            let rawValue = compactValue(for: modelWindow.window)
            let value = percentSuffixed(rawValue)
            metrics.append(StatusItemMetric(label: label, value: value, isModelScoped: true))
        }

        // 2. Five-hour window (included only when it has a percentage OR is still loading)
        if shouldIncludeWindow(snapshot.fiveHour) {
            let rawValue = compactValue(for: snapshot.fiveHour)
            let value = percentSuffixed(rawValue)
            metrics.append(StatusItemMetric(label: "5h", value: value, isModelScoped: false))
        }

        // 3. Long window with label from its kind (included only when it has a percentage OR is still loading)
        if shouldIncludeWindow(snapshot.weekly) {
            let rawValue = compactValue(for: snapshot.weekly)
            let value = percentSuffixed(rawValue)
            let label = longWindowLabel(for: snapshot.weekly.kind)
            metrics.append(StatusItemMetric(label: label, value: value, isModelScoped: false))
        }

        // 4. Optional pacing metric
        if let paceValue = UsagePacing.formattedDelta(for: snapshot.pacingWindow) {
            metrics.append(StatusItemMetric(label: "p", value: paceValue, isModelScoped: false))
        }

        return StatusItemProviderUsage(name: name, metrics: metrics)
    }

    static func text(prefix: String, snapshot: ProviderSnapshot) -> String {
        let usage = content(name: prefix, snapshot: snapshot)
        var parts = [usage.name]

        for metric in usage.metrics {
            parts.append("\(metric.label) \(metric.value)")
        }

        return parts.joined(separator: " · ")
    }

    // MARK: - Private Helpers

    private static func truncatedModelName(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Model" : String(trimmed.prefix(7))
    }

    private static func percentSuffixed(_ value: String) -> String {
        value == "--" ? value : "\(value)%"
    }

    private static func shouldIncludeWindow(_ window: UsageWindow) -> Bool {
        // Include when it has a percentage OR is still loading (message nil or exactly "Loading…")
        return window.usedPercentage != nil ||
               window.message == nil ||
               window.message == "Loading…"
    }

    private static func longWindowLabel(for kind: UsageWindowKind) -> String {
        switch kind {
        case .fiveHour:
            return "5h"
        case .weekly, .modelWeekly:
            return "7d"
        case .monthly:
            return "1m"
        }
    }
}
