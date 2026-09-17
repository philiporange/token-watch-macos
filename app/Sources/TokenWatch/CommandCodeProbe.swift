import Foundation

struct CommandCodeProbe: Sendable {
    private let credentialLoader: CommandCodeCredentialLoader
    private let apiClient: CommandCodeAPIClient

    init(
        credentialLoader: CommandCodeCredentialLoader = CommandCodeCredentialLoader(),
        apiClient: CommandCodeAPIClient = CommandCodeAPIClient()
    ) {
        self.credentialLoader = credentialLoader
        self.apiClient = apiClient
    }

    func fetch() async -> ProviderSnapshot {
        guard let apiKey = credentialLoader.loadAPIKey() else {
            return failureSnapshot(CommandCodeError.credentialsNotFound.localizedDescription)
        }

        do {
            let credits = try await apiClient.fetchCredits(apiKey)
            let subscription = try? await apiClient.fetchSubscription(apiKey)
            let plan = subscription?.planId.flatMap(CommandCodePlan.init(planId:))

            var modelWindows: [ModelUsageWindow] = []
            if let plan, let remaining = credits.monthlyCredits {
                let used = max(0, min(100, (plan.monthlyCredits - remaining) / plan.monthlyCredits * 100))
                modelWindows.append(ModelUsageWindow(
                    modelName: "Credits",
                    window: UsageWindow(
                        kind: .monthly,
                        usedPercentage: used,
                        resetsAt: subscription?.currentPeriodEnd,
                        message: nil
                    ),
                    isActive: true
                ))
            }

            return ProviderSnapshot(
                provider: .commandCode,
                fiveHour: window(kind: .fiveHour, limit: credits.fiveHour, missing: "No 5h limit returned."),
                weekly: window(kind: .weekly, limit: credits.weekly, missing: "No weekly limit returned."),
                modelWindows: modelWindows,
                detail: Self.detail(plan: plan, remainingCredits: credits.monthlyCredits)
            )
        } catch {
            return failureSnapshot(error.localizedDescription)
        }
    }

    static func detail(plan: CommandCodePlan?, remainingCredits: Double?) -> String? {
        var parts: [String] = []
        if let plan {
            parts.append("\(plan.name) plan")
        }
        if let remainingCredits {
            parts.append(String(format: "$%.2f credits left", remainingCredits))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func window(kind: UsageWindowKind, limit: CommandCodeWindowLimit?, missing: String) -> UsageWindow {
        guard let limit, let used = limit.used, let cap = limit.cap, cap > 0 else {
            return UsageWindow(kind: kind, usedPercentage: nil, resetsAt: nil, message: missing)
        }
        return UsageWindow(
            kind: kind,
            usedPercentage: used / cap * 100,
            resetsAt: limit.resetAt.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1_000) : nil },
            message: nil
        )
    }

    private func failureSnapshot(_ message: String) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: .commandCode,
            fiveHour: UsageWindow(kind: .fiveHour, usedPercentage: nil, resetsAt: nil, message: message),
            weekly: UsageWindow(kind: .weekly, usedPercentage: nil, resetsAt: nil, message: message),
            detail: nil
        )
    }

    // MARK: - Live requests

    static let baseURL = "https://api.commandcode.ai"

    static func liveFetchCredits(with apiKey: String) async throws -> CommandCodeCredits {
        try await decode(CommandCodeCredits.self, request: request(path: "/alpha/billing/credits", apiKey: apiKey))
    }

    static func liveFetchSubscription(with apiKey: String) async throws -> CommandCodeSubscription {
        try await decode(CommandCodeSubscriptionResponse.self, request: request(path: "/alpha/billing/subscriptions", apiKey: apiKey)).data
    }

    static func request(path: String, apiKey: String) -> URLRequest {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(
            "Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TokenWatch", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func decode<Response: Decodable>(_ type: Response.Type, request: URLRequest) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CommandCodeError.invalidResponse("Command Code request failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw CommandCodeError.invalidResponse("Command Code returned an invalid response.")
        }
        switch http.statusCode {
        case 200 ..< 300:
            do {
                return try JSONDecoder().decode(Response.self, from: data)
            } catch {
                throw CommandCodeError.invalidResponse("Command Code response could not be read.")
            }
        case 401, 403:
            throw CommandCodeError.authenticationFailed
        default:
            throw CommandCodeError.invalidResponse("Command Code returned HTTP \(http.statusCode).")
        }
    }
}

struct CommandCodeCredentialLoader: Sendable {
    private let homeDirectory: URL
    private let environment: [String: String]

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    /// The CLI's own login lives in `~/.commandcode/auth.json`; an explicit key
    /// in the environment takes precedence, matching the CLI.
    func loadAPIKey() -> String? {
        if let key = Self.trimmed(environment["COMMANDCODE_API_KEY"]) {
            return key
        }
        let url = homeDirectory.appendingPathComponent(".commandcode").appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return Self.trimmed(root["apiKey"] as? String)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct CommandCodeAPIClient: Sendable {
    let fetchCredits: @Sendable (String) async throws -> CommandCodeCredits
    let fetchSubscription: @Sendable (String) async throws -> CommandCodeSubscription

    init(
        fetchCredits: @escaping @Sendable (String) async throws -> CommandCodeCredits = CommandCodeProbe.liveFetchCredits(with:),
        fetchSubscription: @escaping @Sendable (String) async throws -> CommandCodeSubscription = CommandCodeProbe.liveFetchSubscription(with:)
    ) {
        self.fetchCredits = fetchCredits
        self.fetchSubscription = fetchSubscription
    }
}

/// Monthly credit allowance per plan, as tabulated by the Command Code CLI.
struct CommandCodePlan: Sendable, Equatable {
    static let table: [(prefix: String, name: String, credits: Double)] = [
        ("individual-goat", "GOAT", 70),
        ("individual-go", "Go", 10),
        ("individual-pro-v1", "Pro", 80),
        ("individual-provider", "Provider", 15),
        ("individual-pro", "Pro", 30),
        ("individual-max", "Max", 150),
        ("individual-ultra", "Ultra", 300),
        ("teams-pro", "Teams Pro", 40),
    ]

    let name: String
    let monthlyCredits: Double

    init?(planId: String) {
        let normalized = planId.lowercased().replacingOccurrences(of: "_", with: "-")
        let matches = Self.table
            .filter { normalized.hasPrefix($0.prefix) }
            .sorted { $0.prefix.count > $1.prefix.count }
        guard let match = matches.first else {
            return nil
        }
        name = match.name
        monthlyCredits = match.credits
    }
}

struct CommandCodeWindowLimit: Decodable, Sendable, Equatable {
    let used: Double?
    let cap: Double?
    let resetAt: Double?

    init(used: Double?, cap: Double?, resetAt: Double? = nil) {
        self.used = used
        self.cap = cap
        self.resetAt = resetAt
    }

    enum CodingKeys: String, CodingKey {
        case used, cap, resetAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        used = container.flexibleDouble(forKey: .used)
        cap = container.flexibleDouble(forKey: .cap)
        resetAt = container.flexibleDouble(forKey: .resetAt)
    }
}

struct CommandCodeCredits: Decodable, Sendable, Equatable {
    let monthlyCredits: Double?
    let fiveHour: CommandCodeWindowLimit?
    let weekly: CommandCodeWindowLimit?

    init(monthlyCredits: Double?, fiveHour: CommandCodeWindowLimit?, weekly: CommandCodeWindowLimit?) {
        self.monthlyCredits = monthlyCredits
        self.fiveHour = fiveHour
        self.weekly = weekly
    }

    enum CodingKeys: String, CodingKey {
        case credits, windowLimits
    }

    enum CreditsKeys: String, CodingKey {
        case monthlyCredits
    }

    enum WindowKeys: String, CodingKey {
        case fiveHour, weekly
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let credits = try? container.nestedContainer(keyedBy: CreditsKeys.self, forKey: .credits)
        monthlyCredits = credits?.flexibleDouble(forKey: .monthlyCredits)
        let windows = try? container.nestedContainer(keyedBy: WindowKeys.self, forKey: .windowLimits)
        fiveHour = try windows?.decodeIfPresent(CommandCodeWindowLimit.self, forKey: .fiveHour)
        weekly = try windows?.decodeIfPresent(CommandCodeWindowLimit.self, forKey: .weekly)
    }
}

struct CommandCodeSubscriptionResponse: Decodable, Sendable {
    let data: CommandCodeSubscription
}

struct CommandCodeSubscription: Decodable, Sendable, Equatable {
    let planId: String?
    let currentPeriodEnd: Date?

    init(planId: String?, currentPeriodEnd: Date?) {
        self.planId = planId
        self.currentPeriodEnd = currentPeriodEnd
    }

    enum CodingKeys: String, CodingKey {
        case planId, currentPeriodEnd
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planId = try container.decodeIfPresent(String.self, forKey: .planId)
        let raw = try container.decodeIfPresent(String.self, forKey: .currentPeriodEnd)
        currentPeriodEnd = raw.flatMap { value in
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        }
    }
}

enum CommandCodeError: LocalizedError, Sendable, Equatable {
    case credentialsNotFound
    case authenticationFailed
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .credentialsNotFound:
            return "Command Code credentials not found. Run command-code and sign in."
        case .authenticationFailed:
            return "Command Code authentication failed. Run command-code and sign in again."
        case .invalidResponse(let message):
            return message
        }
    }
}

private extension KeyedDecodingContainer {
    func flexibleDouble(forKey key: Key) -> Double? {
        if let value = try? decode(Double.self, forKey: key) {
            return value
        }
        if let value = try? decode(String.self, forKey: key) {
            return Double(value)
        }
        return nil
    }
}
