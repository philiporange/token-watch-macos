import Foundation

struct ZaiProbe: Sendable {
    private let credentialLoader: ZaiCredentialLoader
    private let apiClient: ZaiAPIClient

    init(
        credentialLoader: ZaiCredentialLoader = ZaiCredentialLoader(),
        apiClient: ZaiAPIClient = ZaiAPIClient()
    ) {
        self.credentialLoader = credentialLoader
        self.apiClient = apiClient
    }

    func fetch() async -> ProviderSnapshot {
        guard let token = credentialLoader.loadToken() else {
            return failureSnapshot("Z.ai API key not found. Set ZAI_API_KEY in ~/.env.")
        }

        do {
            let response = try await apiClient.fetchQuota(token)
            let tokenLimit = response.data?.limits.first { $0.type == "TOKENS_LIMIT" }
            let toolLimit = response.data?.limits.first { $0.type == "TIME_LIMIT" }

            return ProviderSnapshot(
                provider: .zai,
                fiveHour: UsageWindow(
                    kind: .fiveHour,
                    usedPercentage: tokenLimit?.percentage,
                    resetsAt: date(fromMilliseconds: tokenLimit?.nextResetTime),
                    message: tokenLimit == nil ? "No 5h token limit returned." : nil
                ),
                weekly: UsageWindow(
                    kind: .monthly,
                    usedPercentage: toolLimit?.percentage,
                    resetsAt: date(fromMilliseconds: toolLimit?.nextResetTime),
                    message: toolLimit == nil ? "No monthly MCP limit returned." : nil
                ),
                detail: response.data?.planName
            )
        } catch {
            return failureSnapshot(error.localizedDescription)
        }
    }

    private func failureSnapshot(_ message: String) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: .zai,
            fiveHour: UsageWindow(kind: .fiveHour, usedPercentage: nil, resetsAt: nil, message: message),
            weekly: UsageWindow(kind: .monthly, usedPercentage: nil, resetsAt: nil, message: message),
            detail: nil
        )
    }

    private func date(fromMilliseconds value: Double?) -> Date? {
        guard let value, value > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: value / 1_000)
    }

    static func liveFetchQuota(with token: String) async throws -> ZaiQuotaResponse {
        let request = quotaRequest(with: token)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProcessRunnerError.invalidResponse("Z.ai quota endpoint returned an invalid response.")
            }

            switch http.statusCode {
            case 200 ..< 300:
                do {
                    return try JSONDecoder().decode(ZaiQuotaResponse.self, from: data)
                } catch {
                    throw ProcessRunnerError.invalidResponse("Z.ai quota response could not be read.")
                }
            case 401, 403:
                throw ProcessRunnerError.invalidResponse("Z.ai authentication failed.")
            default:
                throw ProcessRunnerError.invalidResponse("Z.ai quota endpoint returned HTTP \(http.statusCode).")
            }
        } catch let error as ProcessRunnerError {
            throw error
        } catch {
            throw ProcessRunnerError.invalidResponse("Z.ai quota request failed: \(error.localizedDescription)")
        }
    }

    static func quotaRequest(with token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(token.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Authorization")
        request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("TokenWatch", forHTTPHeaderField: "User-Agent")
        return request
    }
}

struct ZaiCredentialLoader: Sendable {
    private let homeDirectory: URL
    private let environment: [String: String]

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    func loadToken() -> String? {
        if let token = trimmed(environment["ZAI_API_KEY"]) {
            return token
        }

        return loadFromDotEnv()
    }

    private func loadFromDotEnv() -> String? {
        let url = homeDirectory.appendingPathComponent(".env")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        var values: [String: String] = [:]
        for rawLine in contents.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            }
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else {
                continue
            }

            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               let first = value.first,
               let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value.removeFirst()
                value.removeLast()
            } else if let comment = value.firstIndex(of: "#") {
                value = value[..<comment].trimmingCharacters(in: .whitespaces)
            }
            values[String(key)] = String(value)
        }

        return trimmed(values["ZAI_API_KEY"])
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ZaiAPIClient: Sendable {
    let fetchQuota: @Sendable (String) async throws -> ZaiQuotaResponse

    init(
        fetchQuota: @escaping @Sendable (String) async throws -> ZaiQuotaResponse = ZaiProbe.liveFetchQuota(with:)
    ) {
        self.fetchQuota = fetchQuota
    }
}

struct ZaiQuotaResponse: Decodable, Sendable {
    let data: ZaiQuotaData?
}

struct ZaiQuotaData: Decodable, Sendable {
    let limits: [ZaiQuotaLimit]
    let planName: String?

    enum CodingKeys: String, CodingKey {
        case limits
        case planName
        case plan
        case planType = "plan_type"
        case packageName
    }

    init(limits: [ZaiQuotaLimit], planName: String? = nil) {
        self.limits = limits
        self.planName = planName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limits = (try? container.decodeIfPresent([ZaiQuotaLimit].self, forKey: .limits)) ?? []
        planName = try container.decodeIfPresent(String.self, forKey: .planName)
            ?? container.decodeIfPresent(String.self, forKey: .plan)
            ?? container.decodeIfPresent(String.self, forKey: .planType)
            ?? container.decodeIfPresent(String.self, forKey: .packageName)
    }
}

struct ZaiQuotaLimit: Decodable, Sendable {
    let type: String
    let percentage: Double?
    let nextResetTime: Double?

    enum CodingKeys: String, CodingKey {
        case type
        case percentage
        case nextResetTime
    }

    init(type: String, percentage: Double?, nextResetTime: Double? = nil) {
        self.type = type
        self.percentage = percentage
        self.nextResetTime = nextResetTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        percentage = container.flexibleDouble(forKey: .percentage)
        nextResetTime = container.flexibleDouble(forKey: .nextResetTime)
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
