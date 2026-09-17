import Foundation

struct MuseProbe: Sendable {
    private let credentialLoader: MuseCredentialLoader
    private let apiClient: MuseAPIClient

    init(
        credentialLoader: MuseCredentialLoader = MuseCredentialLoader(),
        apiClient: MuseAPIClient = MuseAPIClient()
    ) {
        self.credentialLoader = credentialLoader
        self.apiClient = apiClient
    }

    func fetch() async -> ProviderSnapshot {
        let accessToken: String
        do {
            accessToken = try credentialLoader.loadAccessToken()
        } catch {
            return failureSnapshot(error.localizedDescription)
        }

        do {
            let response = try await apiClient.fetchAccount(accessToken)
            let window = response.subscriptionUsage?.window
            let weekly = response.subscriptionUsage?.weekly

            return ProviderSnapshot(
                provider: .muse,
                fiveHour: UsageWindow(
                    kind: .fiveHour,
                    usedPercentage: window?.usedPercent,
                    resetsAt: date(fromSeconds: window?.resetsAt),
                    message: window == nil ? "No 5h limit returned." : nil
                ),
                weekly: UsageWindow(
                    kind: .weekly,
                    usedPercentage: weekly?.usedPercent,
                    resetsAt: date(fromSeconds: weekly?.resetsAt),
                    message: weekly == nil ? "No weekly limit returned." : nil
                ),
                detail: response.subscriptionTierName
            )
        } catch {
            return failureSnapshot(error.localizedDescription)
        }
    }

    private func failureSnapshot(_ message: String) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: .muse,
            fiveHour: UsageWindow(kind: .fiveHour, usedPercentage: nil, resetsAt: nil, message: message),
            weekly: UsageWindow(kind: .weekly, usedPercentage: nil, resetsAt: nil, message: message),
            detail: nil
        )
    }

    private func date(fromSeconds value: Double?) -> Date? {
        guard let value, value > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: value)
    }

    static func liveFetchAccount(with accessToken: String) async throws -> MuseAccountResponse {
        let request = accountRequest(with: accessToken)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MuseError.invalidResponse("Muse account endpoint returned an invalid response.")
            }

            switch http.statusCode {
            case 200 ..< 300:
                do {
                    return try JSONDecoder().decode(MuseAccountResponse.self, from: data)
                } catch {
                    throw MuseError.invalidResponse("Muse account response could not be read.")
                }
            case 401, 403:
                throw MuseError.authenticationFailed
            default:
                throw MuseError.invalidResponse("Muse account endpoint returned HTTP \(http.statusCode).")
            }
        } catch let error as MuseError {
            throw error
        } catch {
            throw MuseError.invalidResponse("Muse account request failed: \(error.localizedDescription)")
        }
    }

    /// The Muse CLI re-mints its API key from the OAuth login on every start.
    /// The same call returns the subscription usage windows and is idempotent.
    static func accountRequest(with accessToken: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.meta.ai/muse-code/key")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = Data("{}".utf8)
        request.setValue(
            "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("1.0.0", forHTTPHeaderField: "x-api-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TokenWatch", forHTTPHeaderField: "User-Agent")
        return request
    }
}

struct MuseCredentialLoader: Sendable {
    static let keychainService = "ai.meta.dev.credentials"
    static let keychainAccount = "meta"

    private let homeDirectory: URL
    private let environment: [String: String]
    private let keychainLoadOverride: Result<String?, MuseError>?

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychainLoadOverride: Result<String?, MuseError>? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.keychainLoadOverride = keychainLoadOverride
    }

    /// The muse launcher prefers a token stored in auth.json and falls back to
    /// the Keychain entry the CLI writes when auth.json says `storage: keychain`.
    func loadAccessToken() throws -> String {
        if let token = loadFromAuthFile() {
            return token
        }

        switch loadFromKeychain() {
        case .success(let raw?):
            return try decodeSecret(raw)
        case .success(nil):
            throw MuseError.credentialsNotFound
        case .failure(let error):
            throw error
        }
    }

    func decodeSecret(_ raw: String) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)),
              let root = object as? [String: Any],
              let token = Self.trimmed(root["access_token"] as? String) else {
            throw MuseError.invalidCredentials
        }
        return token
    }

    var authFileURL: URL {
        let configDirectory: URL
        if let xdg = Self.trimmed(environment["XDG_CONFIG_HOME"]) {
            configDirectory = URL(fileURLWithPath: NSString(string: xdg).expandingTildeInPath)
        } else {
            configDirectory = homeDirectory.appendingPathComponent(".config")
        }
        return configDirectory.appendingPathComponent("muse").appendingPathComponent("auth.json")
    }

    private func loadFromAuthFile() -> String? {
        guard let data = try? Data(contentsOf: authFileURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let providers = root["providers"] as? [String: Any],
              let meta = providers["meta"] as? [String: Any] else {
            return nil
        }
        return Self.trimmed(meta["access_token"] as? String)
    }

    private func loadFromKeychain() -> Result<String?, MuseError> {
        if let keychainLoadOverride {
            return keychainLoadOverride
        }
        do {
            let raw = try ProcessRunner.runSync(
                executable: "/usr/bin/security",
                arguments: [
                    "find-generic-password",
                    "-s", Self.keychainService,
                    "-a", Self.keychainAccount,
                    "-w",
                ],
                input: nil,
                timeout: 10,
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

    private static func trimmed(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct MuseAPIClient: Sendable {
    let fetchAccount: @Sendable (String) async throws -> MuseAccountResponse

    init(
        fetchAccount: @escaping @Sendable (String) async throws -> MuseAccountResponse = MuseProbe.liveFetchAccount(with:)
    ) {
        self.fetchAccount = fetchAccount
    }
}

enum MuseError: LocalizedError, Sendable, Equatable {
    case credentialsNotFound
    case invalidCredentials
    case keychainAccessDenied
    case authenticationFailed
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .credentialsNotFound:
            return "Muse credentials not found. Run muse login."
        case .invalidCredentials:
            return "Muse credentials could not be read."
        case .keychainAccessDenied:
            return "Muse Keychain access denied."
        case .authenticationFailed:
            return "Muse authentication failed. Run muse login again."
        case .invalidResponse(let message):
            return message
        }
    }
}

struct MuseAccountResponse: Decodable, Sendable {
    let subscriptionTierName: String?
    let subscriptionUsage: MuseSubscriptionUsage?

    enum CodingKeys: String, CodingKey {
        case subscriptionTierName = "subs_tier_name"
        case subscriptionUsage = "subs_usage"
    }

    init(subscriptionTierName: String? = nil, subscriptionUsage: MuseSubscriptionUsage? = nil) {
        self.subscriptionTierName = subscriptionTierName
        self.subscriptionUsage = subscriptionUsage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subscriptionTierName = try container.decodeIfPresent(String.self, forKey: .subscriptionTierName)
        subscriptionUsage = try container.decodeIfPresent(MuseSubscriptionUsage.self, forKey: .subscriptionUsage)
    }
}

struct MuseSubscriptionUsage: Decodable, Sendable {
    let window: MuseUsageWindow?
    let weekly: MuseUsageWindow?

    init(window: MuseUsageWindow? = nil, weekly: MuseUsageWindow? = nil) {
        self.window = window
        self.weekly = weekly
    }

    enum CodingKeys: String, CodingKey {
        case window
        case weekly
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        window = try container.decodeIfPresent(MuseUsageWindow.self, forKey: .window)
        weekly = try container.decodeIfPresent(MuseUsageWindow.self, forKey: .weekly)
    }
}

struct MuseUsageWindow: Decodable, Sendable {
    let usedPercent: Double?
    let resetsAt: Double?
    let windowDurationMinutes: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetsAt = "resets_at"
        case windowDurationMinutes = "window_duration_mins"
    }

    init(usedPercent: Double?, resetsAt: Double? = nil, windowDurationMinutes: Double? = nil) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowDurationMinutes = windowDurationMinutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = container.flexibleDouble(forKey: .usedPercent)
        resetsAt = container.flexibleDouble(forKey: .resetsAt)
        windowDurationMinutes = container.flexibleDouble(forKey: .windowDurationMinutes)
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
