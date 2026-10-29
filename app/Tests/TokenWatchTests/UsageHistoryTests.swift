import Foundation
import Testing
@testable import TokenWatch

struct UsageHistoryTests {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private var now: Date { date("2026-10-29T12:00:00Z") }
    private func point(_ text: String, _ used: Double, reset: Date? = nil) -> UsageHistoryPoint {
        .init(t: date(text), used: used, resetsAt: reset)
    }
    private func series(provider: ProviderKind = .claude, window: String = "weekly", label: String = "Weekly",
                        kind: String = "Week", points: [UsageHistoryPoint] = [], current: UsageHistoryPoint) -> UsageHistorySeries {
        .init(id: provider.routeKey + "." + window, provider: provider.routeKey, providerName: provider.rawValue,
              window: window, label: label, kind: kind, points: points, current: current)
    }
    private func near(_ actual: Double, _ expected: Double) { #expect(abs(actual - expected) < 0.01) }

    @Test func recordingVectorR() async throws {
        let store = UsageHistoryStore()
        for (minutes, used) in [(0, 30.0), (10, 30.5), (20, 31.0), (80, 31.2), (90, 30.0)] {
            try await store.record(makeSnapshot(.claude, fiveHourUsed: used), at: now.addingTimeInterval(Double(minutes) * 60))
            if minutes == 10 {
                let response = try await store.history(range: .all, now: now)
                #expect(response.series.first?.points.count == 1)
                #expect(response.series.first?.current.used == 30.5)
            }
        }
        let response = try await store.history(range: .all, now: now)
        #expect(response.series.first?.points.map(\.used) == [30, 31, 31.2, 30])
        try await store.record(makeSnapshot(.claude), at: now.addingTimeInterval(100 * 60))
        let afterNil = try await store.history(range: .all, now: now)
        #expect(afterNil == response)
        let baseline = UsageHistoryPoint(t: now, used: 30)
        #expect(UsageHistory.shouldStore(.init(t: now, used: 31 - 5e-10), after: baseline))
        #expect(!UsageHistory.shouldStore(.init(t: now, used: 31 - 2e-9), after: baseline))
    }

    @Test func extractionSlugsMonthlyAndNilWindows() {
        var snapshot = makeSnapshot(.zai, modelWindows: [
            .init(modelName: "  OPUS / 4.5! ", window: makeWindow(.modelWeekly, used: 40), isActive: true),
            .init(modelName: "opus---4.5", window: makeWindow(.modelWeekly, used: 90), isActive: false),
            .init(modelName: "No Usage", window: makeWindow(.modelWeekly), isActive: true)
        ])
        snapshot.weekly = makeWindow(.monthly, used: 10)
        let result = UsageHistory.extract(snapshot, at: now.addingTimeInterval(0.7))
        #expect(result.map(\.id) == ["zai.weekly", "zai.model:opus-4-5"])
        #expect(result.map(\.label) == ["Monthly", "  OPUS / 4.5! "])
        #expect(result.first?.kind == "Month")
        #expect(result.last?.current.used == 40)
        #expect(result.first?.current.t == now.addingTimeInterval(1))
    }

    @Test func persistenceRoundTripAndStoredCurrent() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/history.sqlite3")
        let store = UsageHistoryStore(url: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try await store.record(makeSnapshot(.codex, weeklyUsed: 42, weeklyReset: now.addingTimeInterval(86400)), at: now)
        try await store.record(makeSnapshot(.codex, weeklyUsed: 42.5), at: now.addingTimeInterval(60))
        let before = try await store.history(range: .all, now: now)
        #expect(before.series.first?.current.used == 42.5)
        let reopened = UsageHistoryStore(url: url)
        let after = try await reopened.history(range: .all, now: now)
        #expect(after.series.first?.points == before.series.first?.points)
        #expect(after.series.first?.current == before.series.first?.points.last)
        try await reopened.record(makeSnapshot(.codex, weeklyUsed: 43), at: now.addingTimeInterval(120))
        #expect(try await reopened.history(range: .all, now: now).series.first?.points.count == 2)
    }

    @Test func projectionVectorV1() throws {
        let reset = date("2026-10-29T15:00:00Z")
        let current = UsageHistoryPoint(t: now, used: 30, resetsAt: reset)
        let result = UsageHistory.projections(current: current, samples: [point("2026-10-29T10:30:00Z", 5),
            point("2026-10-29T11:00:00Z", 10), point("2026-10-29T11:30:00Z", 20)], kind: "5h")
        #expect(result.map(\.method) == ["average", "trend"])
        near(result[0].ratePerHour, 15); near(result[0].atReset, 75)
        near(result[1].ratePerHour, 20); near(result[1].atReset, 90)
        for projection in result { #expect(projection.limitAt == nil); #expect(projection.to.t == reset) }
    }

    @Test func projectionVectorsV2ThroughV5() {
        let reset = date("2026-11-03T00:00:00Z")
        let current = UsageHistoryPoint(t: now, used: 30, resetsAt: reset)
        let samples = [point("2026-10-27T06:00:00Z", 2), point("2026-10-28T12:00:00Z", 10), point("2026-10-29T00:00:00Z", 20)]
        let result = UsageHistory.projections(current: current, samples: samples, kind: "Week")
        #expect(result.count == 2)
        near(result[0].ratePerHour, 0.5); near(result[0].atReset, 84)
        #expect(result[0].limitAt == nil); #expect(result[0].to.t == reset)
        near(result[1].ratePerHour, 0.8333); near(result[1].atReset, 120)
        #expect(result[1].limitAt == date("2026-11-02T00:00:00Z"))
        #expect(result[1].to == .init(t: date("2026-11-02T00:00:00Z"), used: 100))
        #expect(UsageHistory.projections(current: .init(t: now, used: 30), samples: samples, kind: "Week").isEmpty)
        #expect(UsageHistory.projections(current: current, samples: [], kind: "Week").map(\.method) == ["average"])
        let atLimit = UsageHistory.projections(current: .init(t: now, used: 100, resetsAt: reset), samples: [], kind: "Week")
        #expect(atLimit.first?.limitAt == now)
        #expect(atLimit.first?.to == atLimit.first?.from)
    }

    @Test func projectionBoundariesAndMonthLookback() {
        #expect(UsageHistory.projections(current: .init(t: now, used: 10, resetsAt: now), samples: [], kind: "5h").isEmpty)
        let reset = now.addingTimeInterval(5 * 3600 - 899)
        #expect(UsageHistory.projections(current: .init(t: now, used: 10, resetsAt: reset), samples: [], kind: "5h").isEmpty)
        let monthly = UsageHistory.projections(current: .init(t: now, used: 30, resetsAt: now.addingTimeInterval(360 * 3600)),
            samples: [.init(t: now.addingTimeInterval(-72 * 3600), used: 40), .init(t: now.addingTimeInterval(-36 * 3600), used: 35)], kind: "Month")
        #expect(monthly.map(\.method) == ["average", "trend"])
        near(monthly[0].ratePerHour, 30 / 360)
        near(monthly[1].ratePerHour, 0)
    }

    @Test func responseFilteringOrderingAndJSON() throws {
        let old = UsageHistoryPoint(t: now.addingTimeInterval(-8 * 86400), used: 10)
        let current = UsageHistoryPoint(t: now, used: 30, resetsAt: date("2026-11-03T00:00:00Z"))
        let items = [series(provider: .codex, current: current),
            series(window: "model:z", label: "Zulu", points: [old], current: current),
            series(window: "weekly", points: [old], current: current),
            series(window: "model:a", label: "Alpha", current: current),
            series(window: "five_hour", kind: "5h", points: [current, old], current: current),
            series(provider: .gemini, points: [old], current: old)]
        let response = UsageHistory.response(series: items, range: .week, now: now)
        #expect(response.series.map(\.id) == ["claude.five_hour", "claude.weekly", "claude.model:a", "claude.model:z", "codex.weekly"])
        #expect(response.series.first?.points == [current])
        #expect(response.series[1].points.isEmpty)
        #expect(response.series[1].projections.first?.ratePerHour == 0.5)
        #expect(UsageHistory.response(series: items, range: .all, provider: .codex, now: now).series.map(\.provider) == ["codex"])
        let allItems = UsageHistory.response(series: items, range: .all, now: now)
        #expect(allItems.series.first?.points == [old, current])
        for range in UsageHistoryRange.allCases {
            let value = UsageHistory.response(series: [], range: range, now: now)
            #expect(value.since == range.duration.map { now.addingTimeInterval(-$0) })
        }
        let boundary = UsageHistoryPoint(t: now.addingTimeInterval(-86400), used: 5)
        let day = UsageHistory.response(series: [series(points: [old, boundary], current: current)], range: .day, now: now)
        #expect(day.series.first?.points == [boundary])
        let encoder = UsageAPIRouter.encoder
        let json = try #require(try JSONSerialization.jsonObject(with: encoder.encode(response)) as? [String: Any])
        #expect(Set(json.keys) == ["generated_at", "range", "since", "rules", "series"])
        #expect(json["generated_at"] as? String == "2026-10-29T12:00:00Z")
        #expect(json["since"] as? String == "2026-10-22T12:00:00Z")
        let rules = try #require(json["rules"] as? [String: Int])
        #expect(rules == ["interval_minutes": 60, "change_points": 1])
        let first = try #require((json["series"] as? [[String: Any]])?.first)
        #expect(Set(first.keys) == ["id", "provider", "provider_name", "window", "label", "kind", "points", "current", "projections"])
        let weekly = try #require((json["series"] as? [[String: Any]])?[1])
        let projection = try #require((weekly["projections"] as? [[String: Any]])?.first)
        #expect(Set(projection.keys) == ["method", "rate_per_hour", "at_reset", "limit_at", "from", "to"])
        #expect(projection["limit_at"] is NSNull)
        let all = UsageHistory.response(series: [], range: .all, now: now)
        let allJSON = try #require(try JSONSerialization.jsonObject(with: encoder.encode(all)) as? [String: Any])
        #expect(allJSON["since"] is NSNull)
        let nilReset = try #require(try JSONSerialization.jsonObject(with: encoder.encode(old)) as? [String: Any])
        #expect(nilReset["resets_at"] is NSNull)
    }

    @Test func chartAppendsCurrentAndClipsProjections() throws {
        let point = UsageHistoryPoint(t: now.addingTimeInterval(-3600), used: 10)
        let current = UsageHistoryPoint(t: now, used: 20)
        let item = series(points: [point], current: current)
        #expect(UsageHistoryChart.points(item) == [point, current])
        let response = UsageHistory.response(series: [item], range: .day, now: now)
        let domain = UsageHistoryChart.domain(series: item, response: response)
        #expect(domain.lowerBound == now.addingTimeInterval(-86400))
        #expect(domain.upperBound == now.addingTimeInterval(21600))
        let projection = UsageHistoryProjection(method: "trend", ratePerHour: 10, atReset: 120, limitAt: nil,
            from: .init(t: now, used: 20), to: .init(t: now.addingTimeInterval(36000), used: 120))
        #expect(UsageHistoryChart.clipped(projection, end: domain.upperBound) == .init(t: domain.upperBound, used: 80))
    }

    @Test @MainActor func storeRecordsFreshReadingsOnly() async throws {
        let history = UsageHistoryStore()
        let suite = "history-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let queue = ProbeQueue([makeSnapshot(.claude, weeklyUsed: 30),
            makeSnapshot(.claude, fiveHourMessage: "HTTP 429 rate limit exceeded"), makeSnapshot(.claude, weeklyUsed: 31)])
        let store = UsageStore(claudeProbe: ProbeStub(queue: queue), codexProbe: ProbeStub(queue: ProbeQueue([makeSnapshot(.codex)])),
            userDefaults: defaults, startRefreshLoop: false, historyStore: history)
        await store.refresh(.claude)
        let first = try await history.history(range: .all)
        await store.refresh(.claude)
        #expect(store.claude.weekly.usedPercentage == 30)
        let failed = try await history.history(range: .all)
        #expect(failed.series == first.series)
        await store.refresh(.claude)
        let fresh = await store.history(range: .all)
        #expect(fresh.series.first?.points.map(\.used) == [30, 31])
        #expect(store.historyRevision == 3)
    }
}
