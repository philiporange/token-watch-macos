import Foundation
import Network
import Security
import SwiftUI
import TokenWatchCore

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var connection: MacConnection?
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isReachable = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var isRequestingFreshReadings = false
    @Published private(set) var lastRemoteRefresh: Date?
    @Published private(set) var applyingResetIDs: Set<String> = []
    let bankedReminders: BankedResetReminders

    private struct CachedReading: Codable {
        let address: String
        let fetchedAt: Date
        let data: Data
    }

    private let cacheURL = URL.applicationSupportDirectory.appendingPathComponent("usage.json")
    private var retrySchedule = ConnectionRetrySchedule()
    private var requestTask: Task<Void, Never>?
    private var requestID: UUID?
    private var requestIsForce = false
    private var requestConnection: MacConnection?
    private var pathMonitor: NWPathMonitor?
    private var monitorID: UUID?
    private let monitorQueue = DispatchQueue(label: "TokenWatch.connection-path")

    var automaticRefreshDelay: TimeInterval { connection == nil ? 60 : retrySchedule.nextDelay }

    init(bankedReminders: BankedResetReminders) {
        self.bankedReminders = bankedReminders
        do {
            connection = try ConnectionKeychain.load()
            if connection == nil,
               let url = Bundle.main.url(forResource: "BootstrapConnection", withExtension: "plist"),
               let data = try? Data(contentsOf: url),
               let values = try? PropertyListDecoder().decode([String: String].self, from: data),
               let address = values["address"], let token = values["token"] {
                let seed = try MacConnection(address: address, token: token)
                try ConnectionKeychain.save(seed)
                connection = seed
            }
        } catch {
            errorMessage = "Could not read the saved connection. Connect to your Mac again."
        }
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(CachedReading.self, from: data),
           cached.address == connection?.address,
           let reading = try? UsageSnapshot.decode(cached.data) {
            snapshot = reading
            fetchedAt = cached.fetchedAt
        }
    }

    func refresh(force: Bool = false) async {
        guard !Task.isCancelled else { return }
        while let running = requestTask {
            let priorID = requestID
            let priorWasForce = requestIsForce
            let sameConnection = requestConnection == connection
            await running.value
            guard !Task.isCancelled else { return }
            if sameConnection && (!force || priorWasForce) { return }
            if requestID == priorID { requestTask = nil }
        }
        guard let requestedConnection = connection else { return }
        let id = UUID()
        let task = Task { @MainActor in
            isRefreshing = true
            isRequestingFreshReadings = force
            defer {
                isRefreshing = false
                isRequestingFreshReadings = false
            }
            do {
                let (reading, data) = try await UsageClient.fetch(requestedConnection, refresh: force)
                guard connection == requestedConnection else { return }
                await accept(reading, data: data, for: requestedConnection)
                retrySchedule.recordSuccess()
                if force { lastRemoteRefresh = .now }
            } catch {
                guard connection == requestedConnection else { return }
                isReachable = false
                retrySchedule.recordFailure()
                errorMessage = friendlyError(error)
            }
        }
        requestTask = task
        requestID = id
        requestIsForce = force
        requestConnection = requestedConnection
        await task.value
        if requestID == id {
            requestTask = nil
            requestID = nil
            requestConnection = nil
        }
    }

    func applyReset(provider: ProviderUsage, reset: BankedReset) async -> BankedResetApplyResult? {
        let key = MacConnection.routeKey(for: provider.provider) + "." + reset.id
        guard let requestedConnection = connection, !applyingResetIDs.contains(key) else { return nil }
        applyingResetIDs.insert(key)
        defer { applyingResetIDs.remove(key) }
        do {
            let result = try await UsageClient.applyReset(requestedConnection,
                providerRouteKey: MacConnection.routeKey(for: provider.provider), resetID: reset.id)
            if let running = requestTask { await running.value }
            guard connection == requestedConnection else { return nil }
            if let updated = snapshot?.replacingProvider(result.usage) {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .custom { date, encoder in
                    var container = encoder.singleValueContainer()
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    try container.encode(formatter.string(from: date))
                }
                if let data = try? encoder.encode(updated) {
                    await accept(updated, data: data, for: requestedConnection)
                }
            }
            await refresh(force: false)
            return result
        } catch {
            errorMessage = friendlyError(error)
            return nil
        }
    }

    func isApplying(_ reset: BankedReset, provider: ProviderUsage) -> Bool {
        applyingResetIDs.contains(MacConnection.routeKey(for: provider.provider) + "." + reset.id)
    }

    func connect(address: String, token: String) async throws {
        let candidate = try MacConnection(address: address, token: token)
        let (reading, data) = try await UsageClient.fetch(candidate)
        try Task.checkCancellation()
        try ConnectionKeychain.save(candidate)
        connection = candidate
        retrySchedule.recordSuccess()
        await accept(reading, data: data, for: candidate)
    }

    func startMonitoring() {
        guard pathMonitor == nil else { return }
        let id = UUID()
        let monitor = NWPathMonitor()
        monitorID = id
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                guard let self, self.monitorID == id else { return }
                await self.refresh()
            }
        }
        monitor.start(queue: monitorQueue)
    }

    func stopMonitoring() {
        monitorID = nil
        pathMonitor?.pathUpdateHandler = nil
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func accept(_ reading: UsageSnapshot, data: Data, for connection: MacConnection) async {
        snapshot = reading
        fetchedAt = .now
        isReachable = true
        errorMessage = nil
        let cached = CachedReading(address: connection.address, fetchedAt: .now, data: data)
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(cached).write(to: cacheURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            errorMessage = "Connected, but this reading could not be saved for offline use."
        }
        await bankedReminders.synchronize(reading)
    }

    func friendlyError(_ error: Error) -> String {
        if let error = error as? ConnectionError { return error.localizedDescription }
        return "Can’t reach your Mac. Keep Token Watch open, enable Share with iPhone, and join the same network."
    }
}

@MainActor
private enum ConnectionKeychain {
    static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.philiporange.TokenWatchPhone",
        kSecAttrAccount as String: "mac-connection",
    ]

    static func load() throws -> MacConnection? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw keychainError(status) }
        return try JSONDecoder().decode(MacConnection.self, from: data)
    }

    static func save(_ connection: MacConnection) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(connection),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw keychainError(status) }
    }

    static func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "The connection could not be saved securely. Please try again."])
    }
}
