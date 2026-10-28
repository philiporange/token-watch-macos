import Foundation
import Network
import SystemConfiguration

// MARK: - Settings

enum UsageAPISettings {
    static let enabledKey = "usageAPIEnabled"
    static let portKey = "usageAPIPort"
    static let defaultPort = 8037
    static let lanEnabledKey = "usageAPILANEnabled"
    static let accessTokenKey = "usageAPIAccessToken"

    static func isLANEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: lanEnabledKey)
    }

    static func accessToken(_ defaults: UserDefaults = .standard) -> String {
        if let token = defaults.string(forKey: accessTokenKey), !token.isEmpty { return token }
        return regenerateAccessToken(defaults)
    }

    @discardableResult
    static func regenerateAccessToken(_ defaults: UserDefaults = .standard) -> String {
        let token = UUID().uuidString + UUID().uuidString
        defaults.set(token, forKey: accessTokenKey)
        return token
    }

    static var lanHostname: String {
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String? { return name + ".local" }
        return ProcessInfo.processInfo.hostName
    }

    static func isEnabled(_ userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: enabledKey)
    }

    static func port(_ userDefaults: UserDefaults = .standard) -> Int {
        let stored = userDefaults.object(forKey: portKey) as? Int ?? defaultPort
        return (1 ... 65_535).contains(stored) ? stored : defaultPort
    }
}

// MARK: - JSON payloads

struct UsageAPIWindow: Encodable, Equatable {
    let kind: String
    let usedPercentage: Double?
    let resetsAt: Date?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
        case message
    }

    init(_ window: UsageWindow) {
        kind = window.kind.rawValue
        usedPercentage = window.usedPercentage
        resetsAt = window.resetsAt
        message = window.message
    }
}

struct UsageAPIModelWindow: Encodable, Equatable {
    let modelName: String
    let window: UsageAPIWindow
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case modelName = "model_name"
        case window
        case isActive = "is_active"
    }
}

struct UsageAPIProviderPayload: Encodable, Equatable {
    let provider: String
    let fiveHour: UsageAPIWindow
    let weekly: UsageAPIWindow
    let modelWindows: [UsageAPIModelWindow]
    let detail: String?
    let paceDelta: Double?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case provider
        case fiveHour = "five_hour"
        case weekly
        case modelWindows = "model_windows"
        case detail
        case paceDelta = "pace_delta"
        case updatedAt = "updated_at"
    }

    init(snapshot: ProviderSnapshot, updatedAt: Date?, now: Date = .now) {
        provider = snapshot.provider.rawValue
        fiveHour = UsageAPIWindow(snapshot.fiveHour)
        weekly = UsageAPIWindow(snapshot.weekly)
        modelWindows = snapshot.modelWindows.map {
            UsageAPIModelWindow(modelName: $0.modelName, window: UsageAPIWindow($0.window), isActive: $0.isActive)
        }
        detail = snapshot.detail
        paceDelta = UsagePacing.delta(for: snapshot.pacingWindow, now: now)
        self.updatedAt = updatedAt
    }
}

struct UsageAPIBulkPayload: Encodable {
    let providers: [String: UsageAPIProviderPayload]
    let lastUpdated: Date?

    enum CodingKeys: String, CodingKey {
        case lastUpdated = "last_updated"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(lastUpdated, forKey: .lastUpdated)
        var dynamic = encoder.container(keyedBy: DynamicKey.self)
        for (key, payload) in providers {
            try dynamic.encode(payload, forKey: DynamicKey(key))
        }
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

extension ProviderKind {
    /// Lower-case path segment used by the local API and the Python server.
    var routeKey: String {
        rawValue.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func from(routeKey: String) -> ProviderKind? {
        allCases.first { $0.routeKey == routeKey.lowercased() }
    }
}

// MARK: - Router

struct UsageAPIResponse: Equatable {
    let status: Int
    let body: Data

    var statusLine: String {
        switch status {
        case 200: return "200 OK"
        case 401: return "401 Unauthorized"
        case 404: return "404 Not Found"
        case 405: return "405 Method Not Allowed"
        default: return "500 Internal Server Error"
        }
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(statusLine)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// Pure request routing so the HTTP surface can be tested without sockets.
struct UsageAPIRouter {
    let providers: (ProviderKind) -> UsageAPIProviderPayload
    let lastUpdated: () -> Date?

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    func respond(method: String, path: String) -> UsageAPIResponse {
        let route = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let segments = route.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if route == "/refresh" && method == "POST" {
            return bulkUsage()
        }
        guard method == "GET" || method == "HEAD" else {
            return error(405, "Method not allowed.")
        }

        if segments == ["health"] {
            return json(["status": "ok"])
        }
        if segments == ["usage"] {
            return bulkUsage()
        }
        if segments.count == 2, segments[0] == "usage" {
            guard let provider = ProviderKind.from(routeKey: segments[1]) else {
                return error(404, "Unknown provider '\(segments[1])'. Known: \(ProviderKind.allCases.map(\.routeKey).joined(separator: ", ")).")
            }
            return json(providers(provider))
        }
        return error(404, "Not found. Try /health, /usage, /usage/<provider>, or POST /refresh.")
    }

    private func bulkUsage() -> UsageAPIResponse {
        let payloads = Dictionary(uniqueKeysWithValues: ProviderKind.allCases.map { ($0.routeKey, providers($0)) })
        return json(UsageAPIBulkPayload(providers: payloads, lastUpdated: lastUpdated()))
    }

    private func json<Value: Encodable>(_ value: Value, status: Int = 200) -> UsageAPIResponse {
        do {
            return UsageAPIResponse(status: status, body: try Self.encoder.encode(value))
        } catch {
            return self.error(500, "Encoding failed: \(error.localizedDescription)")
        }
    }

    private func error(_ status: Int, _ message: String) -> UsageAPIResponse {
        let body = (try? Self.encoder.encode(["error": message])) ?? Data()
        return UsageAPIResponse(status: status, body: body)
    }

    /// Check the actual peer address and a single bearer header before routing any LAN request.
    static func isAuthorized(head: String, peer: NWEndpoint, lanEnabled: Bool, token: String?) -> Bool {
        if isLoopback(peer) { return true }
        guard lanEnabled, let token, !token.isEmpty else { return false }
        let headers = head.components(separatedBy: "\r\n").dropFirst().compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "authorization" else { return nil }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers.count == 1 else { return false }
        let parts = headers[0].split(whereSeparator: { $0 == " " || $0 == "\t" })
        return parts.count == 2 && parts[0].lowercased() == "bearer" && parts[1] == token
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return address.rawValue.first == 127
        case .ipv6(let address):
            let bytes = Array(address.rawValue)
            return bytes == Array(repeating: UInt8(0), count: 15) + [1]
                || (bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 255 && bytes[11] == 255 && bytes[12] == 127)
        default:
            return false
        }
    }

    /// Parse the request line of a minimal HTTP/1.x request head.
    static func parseRequestLine(_ head: String) -> (method: String, path: String)? {
        guard let line = head.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first else {
            return nil
        }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else {
            return nil
        }
        return (String(parts[0]).uppercased(), String(parts[1]))
    }
}

/// KVO-visible mirrors of the API defaults, so changes made in the Options
/// window and from `defaults write` both restart the listener.
extension UserDefaults {
    @objc dynamic var usageAPIEnabled: Bool {
        bool(forKey: UsageAPISettings.enabledKey)
    }

    @objc dynamic var usageAPILANEnabled: Bool { bool(forKey: UsageAPISettings.lanEnabledKey) }
    @objc dynamic var usageAPIAccessToken: String? { string(forKey: UsageAPISettings.accessTokenKey) }

    @objc dynamic var usageAPIPort: Int {
        integer(forKey: UsageAPISettings.portKey)
    }
}

// MARK: - Server

@MainActor
final class UsageAPIServer: ObservableObject {
    enum State: Equatable {
        case stopped
        case listening(port: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .stopped

    private let router: UsageAPIRouter
    private let store: UsageStore
    private let userDefaults: UserDefaults
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var observers: [NSKeyValueObservation] = []
    private var appliedSettings: Settings?
    private var lanEnabled = false
    private var accessToken: String?
    @Published private(set) var sharingOnLAN = false

    private struct Settings: Equatable {
        let enabled: Bool
        let port: Int
        let lan: Bool
        let token: String?
    }

    init(store: UsageStore, userDefaults: UserDefaults = .standard, followSettings: Bool = true) {
        self.store = store
        self.userDefaults = userDefaults
        router = UsageAPIRouter(
            providers: { provider in
                MainActor.assumeIsolated {
                    UsageAPIProviderPayload(
                        snapshot: store.snapshot(for: provider),
                        updatedAt: store.lastUpdatedByProvider[provider]
                    )
                }
            },
            lastUpdated: { MainActor.assumeIsolated { store.lastUpdated } }
        )

        if followSettings {
            applySettings()
            observers = [
                userDefaults.observe(\.usageAPIEnabled) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.applySettings() }
                },
                userDefaults.observe(\.usageAPILANEnabled) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.applySettings() }
                },
                userDefaults.observe(\.usageAPIAccessToken) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.applySettings() }
                },
                userDefaults.observe(\.usageAPIPort) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.applySettings() }
                },
            ]
        }
    }

    /// Release the defaults observer and socket; called by the owner before
    /// discarding the server, since a MainActor deinit cannot touch them.
    func shutdown() {
        observers.forEach { $0.invalidate() }
        observers = []
        stop()
    }

    /// Start, stop, or move the listener to match the current defaults.
    func applySettings() {
        let lan = UsageAPISettings.isLANEnabled(userDefaults)
        let settings = Settings(enabled: UsageAPISettings.isEnabled(userDefaults), port: UsageAPISettings.port(userDefaults),
                                lan: lan, token: lan ? UsageAPISettings.accessToken(userDefaults) : nil)
        guard appliedSettings == nil || appliedSettings! != settings else { return }
        appliedSettings = settings

        stop()
        if settings.enabled {
            start(port: settings.port, lanEnabled: settings.lan, accessToken: settings.token)
        }
    }

    func start(port: Int, lanEnabled: Bool = false, accessToken: String? = nil) {
        stop()
        self.lanEnabled = lanEnabled
        self.accessToken = accessToken
        sharingOnLAN = lanEnabled
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: lanEnabled ? "::" : "127.0.0.1",
                port: NWEndpoint.Port(rawValue: UInt16(port)) ?? .any
            )
            let listener = try NWListener(using: parameters)
            if lanEnabled {
                listener.service = NWListener.Service(name: "Token Watch", type: "_tokenwatch._tcp")
            }
            listener.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor [weak self] in
                    guard let self, self.listener === listener else { return }
                    switch newState {
                    case .ready:
                        self.state = .listening(port: Int(listener.port?.rawValue ?? UInt16(port)))
                    case .failed(let error):
                        self.state = .failed(error.localizedDescription)
                        listener.cancel()
                    case .cancelled:
                        self.state = .stopped
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.accept(connection)
                }
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        state = .stopped
        sharingOnLAN = false
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] newState in
            if case .failed = newState {
                Task { @MainActor [weak self] in self?.connections[id] = nil }
            } else if case .cancelled = newState {
                Task { @MainActor [weak self] in self?.connections[id] = nil }
            }
        }
        connection.start(queue: .main)
        receiveHead(connection, buffer: Data())
    }

    private func receiveHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var buffer = buffer
                if let data {
                    buffer.append(data)
                }
                if error != nil {
                    connection.cancel()
                    return
                }
                guard buffer.count <= 16_384 else {
                    connection.cancel()
                    return
                }
                if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                    let response = await self.respond(to: head, peer: connection.endpoint)
                    self.send(response, on: connection)
                } else if isComplete || buffer.count > 16_384 {
                    connection.cancel()
                } else {
                    self.receiveHead(connection, buffer: buffer)
                }
            }
        }
    }

    func respond(to head: String, peer: NWEndpoint) async -> UsageAPIResponse {
        guard UsageAPIRouter.isAuthorized(head: head, peer: peer,
                                          lanEnabled: lanEnabled, token: accessToken) else {
            return UsageAPIResponse(status: 401, body: Data("{\"error\":\"Unauthorized.\"}".utf8))
        }
        guard let request = UsageAPIRouter.parseRequestLine(head) else {
            return UsageAPIResponse(status: 404, body: Data("{\"error\":\"Malformed request.\"}".utf8))
        }
        if request.method == "POST", request.path.split(separator: "?", maxSplits: 1).first == "/refresh" {
            await store.refresh()
        }
        return router.respond(method: request.method, path: request.path)
    }

    private func send(_ response: UsageAPIResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
