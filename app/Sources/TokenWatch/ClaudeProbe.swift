import Foundation

struct ClaudeAPIClient: Sendable {
    let fetchStatus: @Sendable () async throws -> ClaudeAuthStatus
    let refreshToken: @Sendable (ClaudeCredentialResult, ClaudeCredentialLoader) async throws -> ClaudeCredentialResult
    let fetchUsage: @Sendable (String) async throws -> ClaudeUsageResponse

    init(
        fetchStatus: @escaping @Sendable () async throws -> ClaudeAuthStatus = {
            try await ClaudeProbe.liveFetchStatus()
        },
        refreshToken: @escaping @Sendable (ClaudeCredentialResult, ClaudeCredentialLoader) async throws -> ClaudeCredentialResult = { credentials, loader in
            try await ClaudeProbe.liveRefreshToken(credentials, credentialLoader: loader)
        },
        fetchUsage: @escaping @Sendable (String) async throws -> ClaudeUsageResponse = { accessToken in
            try await ClaudeProbe.liveFetchUsage(with: accessToken)
        }
    ) {
        self.fetchStatus = fetchStatus
        self.refreshToken = refreshToken
        self.fetchUsage = fetchUsage
    }
}

struct ClaudeProbe: @unchecked Sendable {
    private let credentialLoader: ClaudeCredentialLoader
    private let accountInfoResolver: ClaudeAccountInfoResolver
    private let apiClient: ClaudeAPIClient

    init(
        credentialLoader: ClaudeCredentialLoader = .init(),
        accountInfoResolver: ClaudeAccountInfoResolver = .init(),
        apiClient: ClaudeAPIClient = .init()
    ) {
        self.credentialLoader = credentialLoader
        self.accountInfoResolver = accountInfoResolver
        self.apiClient = apiClient
    }

    func fetch() async -> ProviderSnapshot {
        do {
            let accountInfo = accountInfoResolver.resolve()
            let resolution = credentialLoader.resolveCredentials()

            guard var credentials = resolution.credentials else {
                if let issue = resolution.issue {
                    throw ProcessRunnerError.invalidResponse(issue.message)
                }

                let status: ClaudeAuthStatus
                do {
                    status = try await apiClient.fetchStatus()
                } catch {
                    throw ProcessRunnerError.invalidResponse(Self.credentialsNotFoundMessage)
                }

                if status.loggedIn == true {
                    throw ProcessRunnerError.invalidResponse(Self.loggedInWithoutCredentialsMessage)
                }

                throw ProcessRunnerError.invalidResponse(Self.credentialsNotFoundMessage)
            }

            if credentialLoader.needsRefresh(credentials.oauth), credentials.source != .environment {
                guard Self.hasRefreshToken(credentials) else {
                    throw ProcessRunnerError.invalidResponse(Self.sessionExpiredMessage)
                }

                credentials = try await apiClient.refreshToken(credentials, credentialLoader)
            }

            let usage: ClaudeUsageResponse
            do {
                usage = try await apiClient.fetchUsage(credentials.oauth.accessToken)
            } catch {
                guard let processError = error as? ProcessRunnerError,
                      shouldRetryAfterAuthenticationError(processError),
                      credentials.source != .environment,
                      Self.hasRefreshToken(credentials) else {
                    throw error
                }

                credentials = try await apiClient.refreshToken(credentials, credentialLoader)
                usage = try await apiClient.fetchUsage(credentials.oauth.accessToken)
            }

            return makeSnapshot(
                from: usage,
                credentials: credentials,
                accountInfo: accountInfo
            )
        } catch {
            return errorSnapshot(for: error)
        }
    }

    func parseISODate(_ isoString: String?) -> Date? {
        guard let isoString else {
            return nil
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: isoString) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: isoString)
    }

    func detailText(from credentials: ClaudeCredentialResult, accountInfo: ClaudeAccountInfo?) -> String? {
        let tier = credentials.oauth.subscriptionType.map(formatSubscriptionType)
        let identity = accountInfo.flatMap {
            $0.displayName ?? $0.email ?? $0.organizationName
        }

        var components: [String] = []
        if let tier {
            components.append(tier)
        }
        if let identity {
            components.append(identity)
        }

        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    func formatSubscriptionType(_ raw: String) -> String {
        switch raw.lowercased() {
        case "claude_max", "max":
            return "Max"
        case "claude_pro", "pro":
            return "Pro"
        case "api", "claude_api":
            return "API"
        default:
            return raw
        }
    }

    func shouldRetryAfterAuthenticationError(_ error: ProcessRunnerError) -> Bool {
        guard case let .invalidResponse(message) = error else {
            return false
        }

        return message == Self.authenticationFailedMessage
    }

    static func liveFetchStatus() async throws -> ClaudeAuthStatus {
        let output = try await ProcessRunner.run(
            executable: "claude",
            arguments: ["auth", "status", "--json"],
            timeout: 10
        )

        return try JSONDecoder().decode(ClaudeAuthStatus.self, from: Data(output.utf8))
    }

    static func liveRefreshToken(
        _ credentials: ClaudeCredentialResult,
        credentialLoader: ClaudeCredentialLoader
    ) async throws -> ClaudeCredentialResult {
        guard let refreshToken = credentials.oauth.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !refreshToken.isEmpty else {
            return credentials
        }

        guard let url = URL(string: "https://platform.claude.com/v1/oauth/token") else {
            throw ProcessRunnerError.invalidResponse("Claude token refresh failed: Invalid URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestBody: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            "scope": "user:profile user:inference user:sessions:claude_code"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProcessRunnerError.invalidResponse("Claude token refresh failed: Invalid response.")
        }

        switch httpResponse.statusCode {
        case 400, 401:
            throw ProcessRunnerError.invalidResponse(Self.sessionExpiredMessage)
        case 200..<300:
            break
        default:
            throw ProcessRunnerError.invalidResponse(
                "Claude token refresh failed with HTTP \(httpResponse.statusCode)."
            )
        }

        let refreshResponse = try JSONDecoder().decode(ClaudeRefreshResponse.self, from: data)
        guard let accessToken = refreshResponse.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            throw ProcessRunnerError.invalidResponse("Claude token refresh returned no access token.")
        }

        var updated = credentials
        updated.oauth.accessToken = accessToken

        if let returnedRefreshToken = refreshResponse.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !returnedRefreshToken.isEmpty {
            updated.oauth.refreshToken = returnedRefreshToken
        }

        if let expiresIn = refreshResponse.expiresIn {
            updated.oauth.expiresAt = Date().timeIntervalSince1970 * 1000 + Double(expiresIn) * 1000
        }

        credentialLoader.saveCredentials(updated)
        return updated
    }

    static func liveFetchUsage(with accessToken: String) async throws -> ClaudeUsageResponse {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw ProcessRunnerError.invalidResponse("Claude usage request failed: Invalid URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(
            "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("TokenWatch", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ProcessRunnerError.invalidResponse(
                "Claude usage request failed: \(error.localizedDescription)"
            )
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProcessRunnerError.invalidResponse("Claude usage request failed: Invalid response.")
        }

        switch httpResponse.statusCode {
        case 200..<300:
            return try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        case 401, 403:
            throw ProcessRunnerError.invalidResponse(Self.authenticationFailedMessage)
        default:
            throw ProcessRunnerError.invalidResponse(
                "Claude usage endpoint returned HTTP \(httpResponse.statusCode)."
            )
        }
    }

    private static let credentialsNotFoundMessage = "Claude credentials not found."
    private static let loggedInWithoutCredentialsMessage = "Claude is logged in, but credentials could not be read from file, Keychain, or environment."
    private static let sessionExpiredMessage = "Claude session expired; log in again."
    private static let authenticationFailedMessage = "Claude authentication failed."

    private static func hasRefreshToken(_ credentials: ClaudeCredentialResult) -> Bool {
        guard let refreshToken = credentials.oauth.refreshToken else {
            return false
        }

        return !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func makeSnapshot(
        from response: ClaudeUsageResponse,
        credentials: ClaudeCredentialResult,
        accountInfo: ClaudeAccountInfo?
    ) -> ProviderSnapshot {
        let fiveHour: UsageWindow
        if let quota = response.fiveHour {
            fiveHour = UsageWindow(
                kind: .fiveHour,
                usedPercentage: quota.utilization,
                resetsAt: parseISODate(quota.resetsAt),
                message: nil
            )
        } else {
            fiveHour = UsageWindow(
                kind: .fiveHour,
                usedPercentage: nil,
                resetsAt: nil,
                message: "No 5h limit returned."
            )
        }

        let weekly: UsageWindow
        if let quota = response.sevenDay {
            weekly = UsageWindow(
                kind: .weekly,
                usedPercentage: quota.utilization,
                resetsAt: parseISODate(quota.resetsAt),
                message: nil
            )
        } else {
            weekly = UsageWindow(
                kind: .weekly,
                usedPercentage: nil,
                resetsAt: nil,
                message: "No weekly limit returned."
            )
        }

        let modelWindows = response.modelScopedLimits.map { limit in
            ModelUsageWindow(
                modelName: limit.modelName,
                window: UsageWindow(
                    kind: .modelWeekly,
                    usedPercentage: limit.percent,
                    resetsAt: parseISODate(limit.resetsAt),
                    message: nil
                ),
                isActive: limit.isActive
            )
        }

        return ProviderSnapshot(
            provider: .claude,
            fiveHour: fiveHour,
            weekly: weekly,
            modelWindows: modelWindows,
            detail: detailText(from: credentials, accountInfo: accountInfo)
        )
    }

    private func errorSnapshot(for error: Error) -> ProviderSnapshot {
        let message = error.localizedDescription
        return ProviderSnapshot(
            provider: .claude,
            fiveHour: UsageWindow(
                kind: .fiveHour,
                usedPercentage: nil,
                resetsAt: nil,
                message: message
            ),
            weekly: UsageWindow(
                kind: .weekly,
                usedPercentage: nil,
                resetsAt: nil,
                message: message
            ),
            modelWindows: [],
            detail: nil
        )
    }
}

struct ClaudeAuthStatus: Decodable, Sendable {
    let loggedIn: Bool?
}

struct ClaudeUsageResponse: Decodable, Sendable {
    let fiveHour: ClaudeQuotaData?
    let sevenDay: ClaudeQuotaData?
    let limits: [ClaudeLimit]

    init(fiveHour: ClaudeQuotaData?, sevenDay: ClaudeQuotaData?, limits: [ClaudeLimit] = []) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.limits = limits
    }

    var modelScopedLimits: [ClaudeLimit] {
        let candidates = limits.enumerated().compactMap { index, limit -> (Int, ClaudeLimit)? in
            guard limit.kind == "weekly_scoped",
                  limit.percent != nil,
                  !limit.modelName.isEmpty else {
                return nil
            }

            return (index, limit)
        }

        return candidates
            .sorted { lhs, rhs in
                let lhsLimit = lhs.1
                let rhsLimit = rhs.1
                let lhsIsFable = lhsLimit.modelName.lowercased().contains("fable")
                let rhsIsFable = rhsLimit.modelName.lowercased().contains("fable")

                if lhsIsFable != rhsIsFable {
                    return lhsIsFable
                }

                if lhsLimit.isActive != rhsLimit.isActive {
                    return lhsLimit.isActive
                }

                if lhsLimit.percent != rhsLimit.percent {
                    return (lhsLimit.percent ?? 0) > (rhsLimit.percent ?? 0)
                }

                return lhs.0 < rhs.0
            }
            .map(\.1)
    }

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case limits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try container.decodeIfPresent(ClaudeQuotaData.self, forKey: .fiveHour)
        sevenDay = try container.decodeIfPresent(ClaudeQuotaData.self, forKey: .sevenDay)
        limits = (try? container.decode([ClaudeLimit].self, forKey: .limits)) ?? []
    }
}

struct ClaudeQuotaData: Decodable, Sendable {
    let utilization: Double?
    let resetsAt: String?

    private enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct ClaudeLimit: Decodable, Sendable {
    let kind: String
    let percent: Double?
    let resetsAt: String?
    let scope: ClaudeLimitScope?
    let isActive: Bool

    init(kind: String, percent: Double?, resetsAt: String?, modelName: String?, isActive: Bool) {
        self.kind = kind
        self.percent = percent
        self.resetsAt = resetsAt
        self.scope = modelName.map {
            ClaudeLimitScope(model: ClaudeLimitModel(displayName: $0))
        }
        self.isActive = isActive
    }

    var modelName: String {
        scope?.model?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case percent
        case resetsAt = "resets_at"
        case scope
        case isActive = "is_active"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        percent = try container.decodeIfPresent(Double.self, forKey: .percent)
        resetsAt = try container.decodeIfPresent(String.self, forKey: .resetsAt)
        scope = try container.decodeIfPresent(ClaudeLimitScope.self, forKey: .scope)
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
    }
}

struct ClaudeLimitScope: Decodable, Sendable {
    let model: ClaudeLimitModel?
}

struct ClaudeLimitModel: Decodable, Sendable {
    let displayName: String?

    private enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}

struct ClaudeRefreshResponse: Decodable, Sendable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

struct ClaudeRefreshErrorResponse: Decodable, Sendable {
    let error: String?
}
