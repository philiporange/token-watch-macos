import Foundation
import SQLite3

/// UTC seconds are shared by persistence, projection endpoints and the HTTP payload.
func historySecond(_ date: Date) -> Date {
    Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded())
}

enum UsageHistoryRange: String, CaseIterable, Sendable {
    case day = "24h", week = "7d", month = "30d", quarter = "90d", year = "365d", all

    var duration: TimeInterval? {
        switch self {
        case .day: 86400
        case .week: 7 * 86400
        case .month: 30 * 86400
        case .quarter: 90 * 86400
        case .year: 365 * 86400
        case .all: nil
        }
    }
}

struct UsageHistoryPoint: Encodable, Equatable, Sendable {
    let t: Date
    let used: Double
    let resetsAt: Date?

    enum CodingKeys: String, CodingKey { case t, used, resetsAt = "resets_at" }

    init(t: Date, used: Double, resetsAt: Date? = nil) {
        self.t = historySecond(t)
        self.used = used
        self.resetsAt = resetsAt.map(historySecond)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(t, forKey: .t)
        try c.encode(used, forKey: .used)
        try c.encode(resetsAt, forKey: .resetsAt)
    }
}

struct UsageHistoryCoordinate: Encodable, Equatable, Sendable {
    let t: Date
    let used: Double
}

struct UsageHistoryProjection: Encodable, Equatable, Sendable {
    let method: String
    let ratePerHour: Double
    let atReset: Double
    let limitAt: Date?
    let from: UsageHistoryCoordinate
    let to: UsageHistoryCoordinate

    enum CodingKeys: String, CodingKey {
        case method, from, to, ratePerHour = "rate_per_hour", atReset = "at_reset", limitAt = "limit_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(method, forKey: .method)
        try c.encode(ratePerHour, forKey: .ratePerHour)
        try c.encode(atReset, forKey: .atReset)
        try c.encode(limitAt, forKey: .limitAt)
        try c.encode(from, forKey: .from)
        try c.encode(to, forKey: .to)
    }
}

struct UsageHistorySeries: Encodable, Identifiable, Equatable, Sendable {
    let id: String
    let provider: String
    let providerName: String
    let window: String
    var label: String
    var kind: String
    var points: [UsageHistoryPoint]
    var current: UsageHistoryPoint
    var projections: [UsageHistoryProjection] = []

    enum CodingKeys: String, CodingKey {
        case id, provider, window, label, kind, points, current, projections, providerName = "provider_name"
    }
}

struct UsageHistoryResponse: Encodable, Equatable, Sendable {
    let generatedAt: Date
    let range: String
    let since: Date?
    var rules = Rules()
    let series: [UsageHistorySeries]

    struct Rules: Encodable, Equatable, Sendable {
        let intervalMinutes = 60
        let changePoints = 1
        enum CodingKeys: String, CodingKey { case intervalMinutes = "interval_minutes", changePoints = "change_points" }
    }
    enum CodingKeys: String, CodingKey { case generatedAt = "generated_at", range, since, rules, series }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(generatedAt, forKey: .generatedAt)
        try c.encode(range, forKey: .range)
        try c.encode(since, forKey: .since)
        try c.encode(rules, forKey: .rules)
        try c.encode(series, forKey: .series)
    }
}

/// Pure extraction, sampling, projection and response rules shared by the app and API.
enum UsageHistory {
    static func extract(_ snapshot: ProviderSnapshot, at time: Date) -> [UsageHistorySeries] {
        var result: [UsageHistorySeries] = []
        var seen: Set<String> = []
        func append(_ window: UsageWindow, id: String, label: String) {
            guard seen.insert(id).inserted, let used = window.usedPercentage, used.isFinite else { return }
            result.append(.init(id: snapshot.provider.routeKey + "." + id,
                provider: snapshot.provider.routeKey, providerName: snapshot.provider.rawValue,
                window: id, label: label, kind: window.kind.rawValue, points: [],
                current: .init(t: time, used: used, resetsAt: window.resetsAt)))
        }
        append(snapshot.fiveHour, id: "five_hour", label: "5-hour")
        append(snapshot.weekly, id: "weekly", label: snapshot.weekly.kind == .monthly ? "Monthly" : "Weekly")
        for model in snapshot.modelWindows {
            let slug = model.modelName.lowercased()
                .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            append(model.window, id: "model:" + slug, label: model.modelName)
        }
        return result
    }

    static func shouldStore(_ reading: UsageHistoryPoint, after stored: UsageHistoryPoint?) -> Bool {
        guard let stored else { return true }
        return reading.t.timeIntervalSince(stored.t) >= 3600 || abs(reading.used - stored.used) >= 1 - 1e-9
    }

    static func durations(kind: String) -> (window: Double, lookback: Double) {
        switch kind {
        case "5h": (5, 1)
        case "Month": (720, 72)
        default: (168, 24)
        }
    }

    static func projections(current: UsageHistoryPoint, samples: [UsageHistoryPoint], kind: String) -> [UsageHistoryProjection] {
        guard let reset = current.resetsAt, reset > current.t else { return [] }
        let (duration, lookback) = durations(kind: kind)
        let start = reset.addingTimeInterval(-duration * 3600)
        let elapsed = current.t.timeIntervalSince(start) / 3600
        let remaining = reset.timeIntervalSince(current.t) / 3600
        func projection(_ method: String, rate: Double) -> UsageHistoryProjection {
            let atReset = current.used + rate * remaining
            let from = UsageHistoryCoordinate(t: current.t, used: current.used)
            let limit: Date? = current.used >= 100 ? current.t
                : atReset >= 100 && rate > 0 ? historySecond(current.t.addingTimeInterval((100 - current.used) / rate * 3600)) : nil
            let to = current.used >= 100 ? from : UsageHistoryCoordinate(t: limit ?? reset, used: limit == nil ? atReset : 100)
            return .init(method: method, ratePerHour: rate, atReset: atReset, limitAt: limit, from: from, to: to)
        }
        var result: [UsageHistoryProjection] = []
        if elapsed >= 0.25 && elapsed <= duration {
            result.append(projection("average", rate: max(0, current.used) / elapsed))
        }
        let cutoff = max(start, current.t.addingTimeInterval(-lookback * 3600))
        let points = samples.filter { $0.t >= cutoff && $0.t < current.t } + [current]
        if points.count >= 2, let first = points.min(by: { $0.t < $1.t }),
           current.t.timeIntervalSince(first.t) >= lookback * 3600 / 4 {
            let xs = points.map { $0.t.timeIntervalSince(current.t) / 3600 }
            let meanX = xs.reduce(0, +) / Double(points.count)
            let meanY = points.map(\.used).reduce(0, +) / Double(points.count)
            let denominator = xs.reduce(0) { $0 + pow($1 - meanX, 2) }
            let numerator = zip(xs, points).reduce(0) { $0 + ($1.0 - meanX) * ($1.1.used - meanY) }
            if denominator > 0 { result.append(projection("trend", rate: max(0, numerator / denominator))) }
        }
        return result
    }

    static func response(series: [UsageHistorySeries], range: UsageHistoryRange, provider: ProviderKind? = nil,
                         now: Date = .now) -> UsageHistoryResponse {
        let now = historySecond(now)
        let since = range.duration.map { now.addingTimeInterval(-$0) }
        let order = ProviderKind.allCases.map(\.routeKey)
        let included = series.compactMap { item -> UsageHistorySeries? in
            guard provider == nil || item.provider == provider?.routeKey else { return nil }
            var item = item
            item.projections = projections(current: item.current, samples: item.points, kind: item.kind)
            item.points = item.points.filter { since == nil || $0.t >= since! }.sorted { $0.t < $1.t }
            guard since == nil || !item.points.isEmpty || item.current.t >= since! else { return nil }
            return item
        }.sorted { a, b in
            let ap = order.firstIndex(of: a.provider) ?? order.count
            let bp = order.firstIndex(of: b.provider) ?? order.count
            if ap != bp { return ap < bp }
            func rank(_ window: String) -> Int { window == "five_hour" ? 0 : window == "weekly" ? 1 : 2 }
            if rank(a.window) != rank(b.window) { return rank(a.window) < rank(b.window) }
            return a.label == b.label ? a.id < b.id : a.label < b.label
        }
        return .init(generatedAt: now, range: range.rawValue, since: since, series: included)
    }
}

/// Owns the SQLite handle; only UsageHistoryStore accesses it, on its actor executor.
private final class HistoryDatabase: @unchecked Sendable {
    let handle: OpaquePointer
    init(path: String) throws {
        var db: OpaquePointer?
        let status = sqlite3_open(path, &db)
        guard status == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open history database"
            if let db { sqlite3_close(db) }
            throw HistoryStorageError(message: message)
        }
        handle = db
    }
    deinit { sqlite3_close(handle) }
}

struct HistoryStorageError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Lazily opens SQLite and retains each series' latest reading independently of persisted samples.
actor UsageHistoryStore {
    private let url: URL?
    private var database: HistoryDatabase?
    private var lastReadings: [String: UsageHistorySeries] = [:]
    private var lastStored: [String: UsageHistoryPoint]?

    init(url: URL? = nil) { self.url = url }

    static func live() -> UsageHistoryStore {
        UsageHistoryStore(url: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TokenWatch/usage-history.sqlite3"))
    }

    private func connection() throws -> OpaquePointer {
        if let database { return database.handle }
        if let url { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        let db = try HistoryDatabase(path: url?.path ?? ":memory:")
        guard sqlite3_exec(db.handle, "CREATE TABLE IF NOT EXISTS samples(id INTEGER PRIMARY KEY, series TEXT, provider TEXT, window TEXT, label TEXT, kind TEXT, t REAL, used REAL, resets_at REAL NULL); CREATE INDEX IF NOT EXISTS samples_series_t ON samples(series, t);", nil, nil, nil) == SQLITE_OK else {
            throw HistoryStorageError(message: String(cString: sqlite3_errmsg(db.handle)))
        }
        database = db
        return db.handle
    }

    /// Loads samples at or after `since` (all when nil), optionally for one provider.
    private func storedSeries(since: Date? = nil, provider: String? = nil) throws -> [String: UsageHistorySeries] {
        let db = try connection()
        var statement: OpaquePointer?
        let sql = "SELECT series, provider, window, label, kind, t, used, resets_at FROM samples WHERE t >= ?"
            + (provider == nil ? "" : " AND provider = ?") + " ORDER BY t, id"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw HistoryStorageError(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude)
        if let provider {
            _ = provider.withCString { sqlite3_bind_text(statement, 2, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }
        var result: [String: UsageHistorySeries] = [:]
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            func string(_ i: Int32) -> String { String(cString: sqlite3_column_text(statement, i)) }
            let id = string(0), provider = string(1)
            let point = UsageHistoryPoint(t: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                used: sqlite3_column_double(statement, 6), resetsAt: sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil
                    : Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)))
            if result[id] == nil {
                result[id] = .init(id: id, provider: provider, providerName: ProviderKind.from(routeKey: provider)?.rawValue ?? provider,
                    window: string(2), label: string(3), kind: string(4), points: [], current: point)
            }
            result[id]?.label = string(3)
            result[id]?.kind = string(4)
            result[id]?.points.append(point)
            result[id]?.current = point
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw HistoryStorageError(message: String(cString: sqlite3_errmsg(db))) }
        return result
    }

    func record(_ snapshot: ProviderSnapshot, at time: Date = .now) throws {
        let readings = UsageHistory.extract(snapshot, at: time)
        guard !readings.isEmpty else { return }
        for reading in readings { lastReadings[reading.id] = reading }
        if lastStored == nil { lastStored = try storedSeries().mapValues(\.current) }
        let db = try connection()
        for reading in readings {
            guard UsageHistory.shouldStore(reading.current, after: lastStored?[reading.id]) else { continue }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO samples(series, provider, window, label, kind, t, used, resets_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", -1, &statement, nil) == SQLITE_OK else {
                throw HistoryStorageError(message: String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (index, value) in [reading.id, reading.provider, reading.window, reading.label, reading.kind].enumerated() {
                _ = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, transient) }
            }
            sqlite3_bind_double(statement, 6, reading.current.t.timeIntervalSince1970)
            sqlite3_bind_double(statement, 7, reading.current.used)
            if let reset = reading.current.resetsAt { sqlite3_bind_double(statement, 8, reset.timeIntervalSince1970) }
            else { sqlite3_bind_null(statement, 8) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw HistoryStorageError(message: String(cString: sqlite3_errmsg(db))) }
            lastStored?[reading.id] = reading.current
        }
    }

    func history(range: UsageHistoryRange = .week, provider: ProviderKind? = nil, now: Date = .now) throws -> UsageHistoryResponse {
        // Projections look back at most the longest trend window before the earliest reading in range.
        let lookback = UsageHistory.durations(kind: "Month").lookback * 3600
        let since = range.duration.map { historySecond(now).addingTimeInterval(-$0 - lookback) }
        var series = try storedSeries(since: since, provider: provider?.routeKey)
        for (id, reading) in lastReadings where provider == nil || reading.provider == provider?.routeKey {
            var reading = reading
            reading.points = series[id]?.points ?? []
            series[id] = reading
        }
        return UsageHistory.response(series: Array(series.values), range: range, provider: provider, now: now)
    }

    /// Providers with stored samples or a reading this session, without loading samples.
    func providers() throws -> Set<String> {
        let db = try connection()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT DISTINCT provider FROM samples", -1, &statement, nil) == SQLITE_OK else {
            throw HistoryStorageError(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        var result = Set(lastReadings.values.map(\.provider))
        while sqlite3_step(statement) == SQLITE_ROW {
            result.insert(String(cString: sqlite3_column_text(statement, 0)))
        }
        return result
    }
}
