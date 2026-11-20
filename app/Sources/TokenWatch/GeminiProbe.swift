import Foundation

struct GeminiProbe: Sendable {
    private let credentialLoader: AgyCredentialLoader
    private let apiClient: AgyAPIClient

    init(
        credentialLoader: AgyCredentialLoader = AgyCredentialLoader(),
        apiClient: AgyAPIClient = .live
    ) {
        self.credentialLoader = credentialLoader
        self.apiClient = apiClient
    }

    func fetch() async -> ProviderSnapshot {
        let cliSummary = credentialLoader.hasTokenFileOverride ? nil : await apiClient.readCLIQuota()
        do {
            var credential = try credentialLoader.loadCredential()
            if credentialLoader.needsRefresh(credential) {
                credential.accessToken = try await refreshedAccessToken(for: credential)
            }

            let result: AgyQuotaFetchResult
            do {
                result = try await apiClient.fetchQuota(credential.accessToken, cliSummary)
            } catch AgyError.authenticationFailed {
                credential.accessToken = try await refreshedAccessToken(for: credential)
                result = try await apiClient.fetchQuota(credential.accessToken, cliSummary)
            }

            return snapshot(from: result.summary, tier: result.tier)
        } catch {
            if let cliSummary {
                return snapshot(from: cliSummary, tier: nil)
            }
            return failureSnapshot(error.localizedDescription)
        }
    }

    private func refreshedAccessToken(for credential: AgyCredential) async throws -> String {
        guard let refreshToken = credential.refreshToken else {
            throw AgyError.sessionExpired
        }
        return try await apiClient.refreshAccessToken(refreshToken)
    }

    private func snapshot(from summary: AgyQuotaSummary, tier: String?) -> ProviderSnapshot {
        let groups = summary.groups
        guard !groups.isEmpty else {
            return failureSnapshot("Gemini quota response returned no model groups.")
        }

        let primaryIndex = groups.firstIndex { group in
            group.buckets.contains { bucket in
                let id = bucket.bucketId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return id == "gemini-weekly" || id == "gemini-5h"
            }
        } ?? groups.firstIndex {
            ["gemini", "gemini models"].contains($0.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        let primary = primaryIndex.map { groups[$0] }
        let fiveHourBucket = primary?.buckets.first { $0.kind == .fiveHour }
        let weeklyBucket = primary?.buckets.first { $0.kind == .weekly }
        let additionalWindows = groups.indices.filter { $0 != primaryIndex }.flatMap { index in
            let group = groups[index]
            return group.buckets.compactMap { bucket -> ModelUsageWindow? in
                guard let kind = bucket.kind else { return nil }
                return ModelUsageWindow(
                    modelName: "\(group.displayName) · \(bucket.displayName)",
                    window: usageWindow(from: bucket, kind: kind),
                    isActive: false
                )
            }
        }

        let detail = [primary?.displayName, tier]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        return ProviderSnapshot(
            provider: .gemini,
            fiveHour: fiveHourBucket.map { usageWindow(from: $0, kind: .fiveHour) }
                ?? UsageWindow(kind: .fiveHour, usedPercentage: nil, resetsAt: nil, message: "No Gemini 5h limit returned."),
            weekly: weeklyBucket.map { usageWindow(from: $0, kind: .weekly) }
                ?? UsageWindow(kind: .weekly, usedPercentage: nil, resetsAt: nil, message: "No Gemini weekly limit returned."),
            modelWindows: additionalWindows,
            detail: detail.isEmpty ? nil : detail
        )
    }

    private func usageWindow(from bucket: AgyQuotaBucket, kind: UsageWindowKind) -> UsageWindow {
        if bucket.disabled == true {
            return UsageWindow(kind: kind, usedPercentage: nil, resetsAt: parseISODate(bucket.resetTime), message: "Quota disabled.")
        }
        let usedPercentage = bucket.remainingFraction.map {
            (1 - min(max($0, 0), 1)) * 100
        }
        return UsageWindow(
            kind: kind,
            usedPercentage: usedPercentage,
            resetsAt: parseISODate(bucket.resetTime),
            message: usedPercentage == nil ? "Quota unavailable." : nil
        )
    }

    private func failureSnapshot(_ message: String) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: .gemini,
            fiveHour: UsageWindow(kind: .fiveHour, usedPercentage: nil, resetsAt: nil, message: message),
            weekly: UsageWindow(kind: .weekly, usedPercentage: nil, resetsAt: nil, message: message),
            detail: nil
        )
    }

    private func parseISODate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func liveRefreshAccessToken(_ refreshToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": AgyOAuth.clientID,
            "client_secret": AgyOAuth.clientSecret,
        ]
        request.httpBody = fields
            .map { key, value in "\(formEncoded(key))=\(formEncoded(value))" }
            .sorted()
            .joined(separator: "&")
            .data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AgyError.invalidResponse("Gemini token refresh returned an invalid response.")
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                if http.statusCode == 400 || http.statusCode == 401 {
                    throw AgyError.sessionExpired
                }
                throw AgyError.invalidResponse("Gemini token refresh returned HTTP \(http.statusCode).")
            }
            let payload = try JSONDecoder().decode(AgyRefreshResponse.self, from: data)
            guard let token = trimmed(payload.accessToken) else {
                throw AgyError.invalidResponse("Gemini token refresh returned no access token.")
            }
            return token
        } catch let error as AgyError {
            throw error
        } catch {
            throw AgyError.invalidResponse("Gemini token refresh failed: \(error.localizedDescription)")
        }
    }

    static func liveFetchQuota(with accessToken: String, cliSummary: AgyQuotaSummary?) async throws -> AgyQuotaFetchResult {
        var lastError: Error = AgyError.invalidResponse("No Gemini quota host responded.")
        for host in ["daily-cloudcode-pa.googleapis.com", "cloudcode-pa.googleapis.com"] {
            do {
                let load: AgyLoadCodeAssistResponse = try await postInternal(
                    host: host,
                    method: "loadCodeAssist",
                    accessToken: accessToken,
                    body: ["metadata": ["ideType": "ANTIGRAVITY"]]
                )
                if let cliSummary {
                    return AgyQuotaFetchResult(summary: cliSummary, tier: load.tierName, host: host)
                }
                guard let project = trimmed(load.cloudaicompanionProject) else {
                    throw AgyError.invalidResponse("Gemini loadCodeAssist returned no project.")
                }
                let summary: AgyQuotaSummary = try await postInternal(
                    host: host,
                    method: "retrieveUserQuotaSummary",
                    accessToken: accessToken,
                    body: ["project": project]
                )
                return AgyQuotaFetchResult(summary: summary, tier: load.tierName, host: host)
            } catch AgyError.authenticationFailed {
                throw AgyError.authenticationFailed
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    static func internalRequest(
        host: String,
        method: String,
        accessToken: String,
        body: [String: Any]
    ) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://\(host)/v1internal:\(method)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The quota API rejects unknown user agents with 403.
        request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func postInternal<Response: Decodable>(
        host: String,
        method: String,
        accessToken: String,
        body: [String: Any]
    ) async throws -> Response {
        do {
            let request = try internalRequest(host: host, method: method, accessToken: accessToken, body: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AgyError.invalidResponse("Gemini \(method) returned an invalid response.")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw AgyError.authenticationFailed
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                throw AgyError.invalidResponse("Gemini \(method) returned HTTP \(http.statusCode).")
            }
            do {
                return try JSONDecoder().decode(Response.self, from: data)
            } catch {
                throw AgyError.invalidResponse("Gemini \(method) response could not be read.")
            }
        } catch let error as AgyError {
            throw error
        } catch {
            throw AgyError.invalidResponse("Gemini quota request failed: \(error.localizedDescription)")
        }
    }

    private static func formEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}

struct AgyCredential: Sendable, Equatable {
    var accessToken: String
    let refreshToken: String?
    let expiry: Date?
    let authMethod: String?
}

struct AgyCredentialLoader: Sendable {
    private let homeDirectory: URL
    private let environment: [String: String]
    private let keychainLoadOverride: Result<String?, AgyError>?

    var hasTokenFileOverride: Bool { Self.trimmed(environment["AGY_OAUTH_TOKEN_FILE"]) != nil }

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychainLoadOverride: Result<String?, AgyError>? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.keychainLoadOverride = keychainLoadOverride
    }

    func loadCredential() throws -> AgyCredential {
        let keychainResult = loadFromKeychain()
        if case .success(let raw) = keychainResult, let raw {
            return try decodeSecret(raw)
        }
        if let raw = loadFromFile() {
            return try decodeSecret(raw)
        }
        if case .failure(let error) = keychainResult {
            throw error
        }
        throw AgyError.credentialsNotFound
    }

    func needsRefresh(_ credential: AgyCredential, now: Date = .now) -> Bool {
        guard let expiry = credential.expiry else { return false }
        return expiry.timeIntervalSince(now) < 60
    }

    func decodeSecret(_ raw: String) throws -> AgyCredential {
        let prefix = "go-keyring-base64:"
        let payload: Data
        if raw.hasPrefix(prefix) {
            guard let decoded = Data(base64Encoded: String(raw.dropFirst(prefix.count))) else {
                throw AgyError.invalidCredentials
            }
            payload = decoded
        } else {
            payload = Data(raw.utf8)
        }

        guard let object = try? JSONSerialization.jsonObject(with: payload),
              let root = object as? [String: Any] else {
            throw AgyError.invalidCredentials
        }
        let token = (root["token"] as? [String: Any]) ?? root
        guard let accessToken = Self.trimmed(token["access_token"] as? String) else {
            throw AgyError.invalidCredentials
        }
        return AgyCredential(
            accessToken: accessToken,
            refreshToken: Self.trimmed(token["refresh_token"] as? String),
            expiry: parseDate(token["expiry"]),
            authMethod: Self.trimmed(root["auth_method"] as? String)
        )
    }

    private func loadFromKeychain() -> Result<String?, AgyError> {
        if let keychainLoadOverride {
            return keychainLoadOverride
        }
        do {
            let raw = try ProcessRunner.runSync(
                executable: "/usr/bin/security",
                arguments: ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"],
                input: nil,
                timeout: nil,
                currentDirectory: nil
            )
            return .success(Self.trimmed(raw))
        } catch let error as ProcessRunnerError {
            guard case .terminated(_, let output) = error else {
                return .failure(.invalidCredentials)
            }
            let normalized = output.lowercased()
            if normalized.contains("could not be found in the keychain")
                || normalized.contains("item could not be found") {
                return .success(nil)
            }
            if normalized.contains("user interaction is not allowed")
                || normalized.contains("authorization was denied")
                || normalized.contains("user canceled")
                || normalized.contains("user cancelled") {
                return .failure(.keychainAccessDenied)
            }
            return .failure(.invalidCredentials)
        } catch {
            return .failure(.invalidCredentials)
        }
    }

    private func loadFromFile() -> String? {
        let path = Self.trimmed(environment["AGY_OAUTH_TOKEN_FILE"])
            .map { NSString(string: $0).expandingTildeInPath }
        let url = path.map(URL.init(fileURLWithPath:))
            ?? homeDirectory.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Self.trimmed(raw)
    }

    private func parseDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let timestamp = number.doubleValue
            return Date(timeIntervalSince1970: timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp)
        }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}

struct AgyAPIClient: Sendable {
    static let live = AgyAPIClient(
        readCLIQuota: { await AgyCLIUsage.read() },
        fetchQuota: GeminiProbe.liveFetchQuota(with:cliSummary:),
        refreshAccessToken: GeminiProbe.liveRefreshAccessToken
    )

    var readCLIQuota: @Sendable () async -> AgyQuotaSummary? = { nil }
    let fetchQuota: @Sendable (String, AgyQuotaSummary?) async throws -> AgyQuotaFetchResult
    let refreshAccessToken: @Sendable (String) async throws -> String
}

struct AgyCLIUsage: Decodable {
    let status: String
    let command: Command

    struct Command: Decodable {
        let name: String
        let data: AgyQuotaSummary
    }

    static func read(executable: String? = nil) async -> AgyQuotaSummary? {
        await Task.detached(priority: .utility) {
            guard let path = executable ?? ProcessRunner.which("agy") else { return nil }
            func run(_ arguments: [String]) throws -> String {
                try ProcessRunner.runSync(
                    executable: path, arguments: arguments, input: nil, timeout: 20,
                    currentDirectory: FileManager.default.temporaryDirectory
                )
            }
            // Print mode gained a built-in, quota-free /usage command in agy 1.1.11.
            guard let version = try? run(["--version"]).trimmingCharacters(in: .whitespacesAndNewlines),
                  version.wholeMatch(of: /[0-9]+\.[0-9]+\.[0-9]+/) != nil,
                  version.compare("1.1.11", options: .numeric) != .orderedAscending,
                  let output = try? run(["--output-format", "json", "-p", "/usage"]) else { return nil }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            guard let usage = try? decoder.decode(Self.self, from: Data(output.utf8)),
                  usage.status == "SUCCESS", usage.command.name == "usage" else { return nil }
            return usage.command.data
        }.value
    }
}

enum AgyError: LocalizedError, Sendable, Equatable {
    case credentialsNotFound
    case invalidCredentials
    case keychainAccessDenied
    case sessionExpired
    case authenticationFailed
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .credentialsNotFound:
            return "Gemini credentials not found. Run agy and sign in."
        case .invalidCredentials:
            return "Gemini credentials could not be read."
        case .keychainAccessDenied:
            return "Gemini Keychain access denied."
        case .sessionExpired:
            return "Gemini session expired. Run agy and sign in again."
        case .authenticationFailed:
            return "Gemini authentication failed."
        case .invalidResponse(let message):
            return message
        }
    }
}

enum AgyOAuth {
    // agy ships an installed-app OAuth client. These shared values identify the
    // public client; the per-user credential remains in Keychain/token storage.
    static let clientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    static let clientSecret = "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"
}

struct AgyRefreshResponse: Decodable, Sendable {
    let accessToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

struct AgyLoadCodeAssistResponse: Decodable, Sendable {
    let cloudaicompanionProject: String?
    let currentTier: AgyTier?
    let paidTier: AgyTier?

    // currentTier reports the Code Assist tier ("free-tier") even for
    // subscribers; paidTier carries the actual plan ("Google AI Pro").
    var tierName: String? {
        if let paidTier, let name = paidTier.name ?? paidTier.id {
            return name
        }
        return currentTier?.id ?? currentTier?.name
    }
}

struct AgyTier: Decodable, Sendable {
    let id: String?
    let name: String?

    init(id: String?, name: String? = nil) {
        self.id = id
        self.name = name
    }
}

struct AgyQuotaFetchResult: Sendable {
    let summary: AgyQuotaSummary
    let tier: String?
    let host: String
}

struct AgyQuotaSummary: Decodable, Sendable {
    let groups: [AgyQuotaGroup]
    let description: String?

    init(groups: [AgyQuotaGroup], description: String? = nil) {
        self.groups = groups
        self.description = description
    }

    enum CodingKeys: CodingKey {
        case groups
        case description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groups = try container.decode([AgyQuotaGroup].self, forKey: .groups)
        description = try container.decodeIfPresent(String.self, forKey: .description)
    }
}

struct AgyQuotaGroup: Decodable, Sendable {
    let displayName: String
    let description: String?
    let buckets: [AgyQuotaBucket]

    init(displayName: String, description: String? = nil, buckets: [AgyQuotaBucket]) {
        self.displayName = displayName
        self.description = description
        self.buckets = buckets
    }

    enum CodingKeys: CodingKey {
        case displayName
        case name
        case description
        case buckets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            ?? container.decodeIfPresent(String.self, forKey: .name) ?? "Model group"
        description = try container.decodeIfPresent(String.self, forKey: .description)
        buckets = (try? container.decodeIfPresent([AgyQuotaBucket].self, forKey: .buckets)) ?? []
    }
}

struct AgyQuotaBucket: Decodable, Sendable {
    let bucketId: String?
    let displayName: String
    let window: String?
    let remainingFraction: Double?
    let resetTime: String?
    let disabled: Bool?

    init(
        bucketId: String? = nil,
        displayName: String,
        window: String? = nil,
        remainingFraction: Double?,
        resetTime: String? = nil,
        disabled: Bool? = nil
    ) {
        self.bucketId = bucketId
        self.displayName = displayName
        self.window = window
        self.remainingFraction = remainingFraction
        self.resetTime = resetTime
        self.disabled = disabled
    }

    enum CodingKeys: CodingKey {
        case bucketId
        case id
        case displayName
        case name
        case window
        case remainingFraction
        case resetTime
        case disabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bucketId = try container.decodeIfPresent(String.self, forKey: .bucketId)
            ?? container.decodeIfPresent(String.self, forKey: .id)
        displayName = (try? container.decodeIfPresent(String.self, forKey: .displayName))
            ?? (try? container.decodeIfPresent(String.self, forKey: .name))
            ?? (try? container.decodeIfPresent(String.self, forKey: .window))
            ?? "Quota"
        window = try container.decodeIfPresent(String.self, forKey: .window)
        if let value = try? container.decodeIfPresent(Double.self, forKey: .remainingFraction) {
            remainingFraction = value
        } else if let value = try? container.decodeIfPresent(String.self, forKey: .remainingFraction) {
            remainingFraction = Double(value).flatMap { $0.isFinite ? $0 : nil }
        } else {
            remainingFraction = nil
        }
        resetTime = try container.decodeIfPresent(String.self, forKey: .resetTime)
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled)
    }

    var kind: UsageWindowKind? {
        let value = [window, bucketId, displayName]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        if value.contains("weekly") || value.contains("week") {
            return .weekly
        }
        if value.contains("five-hour") || value.contains("five hour") || value.contains("5h") {
            return .fiveHour
        }
        return nil
    }
}
