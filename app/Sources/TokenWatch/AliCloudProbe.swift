import Foundation

/// Alibaba Cloud publishes no usage API for Token Plan keys, so usage is read
/// from the Model Studio console's internal gateway with the console's own
/// login cookie.
struct AliCloudProbe: Sendable {
    private let credentialLoader: AliCloudCredentialLoader
    private let apiClient: AliCloudAPIClient

    init(
        credentialLoader: AliCloudCredentialLoader = AliCloudCredentialLoader(),
        apiClient: AliCloudAPIClient = AliCloudAPIClient()
    ) {
        self.credentialLoader = credentialLoader
        self.apiClient = apiClient
    }

    func fetch() async -> ProviderSnapshot {
        guard let ticket = credentialLoader.loadTicket() else {
            return failureSnapshot(AliCloudError.credentialsNotFound.localizedDescription)
        }

        do {
            let usage = try await apiClient.fetchUsage(ticket)
            let subscription = try? await apiClient.fetchSubscription(ticket)

            return ProviderSnapshot(
                provider: .alicloud,
                fiveHour: UsageWindow(
                    kind: .fiveHour,
                    usedPercentage: nil,
                    resetsAt: nil,
                    message: "Token Plan has no 5h window."
                ),
                weekly: UsageWindow(
                    kind: .weekly,
                    usedPercentage: usage.weeklyFraction.map { $0 * 100 },
                    resetsAt: date(fromMilliseconds: usage.weeklyResetTime),
                    message: usage.weeklyFraction == nil ? "No weekly usage returned." : nil
                ),
                detail: subscription?.detail
            )
        } catch {
            return failureSnapshot(error.localizedDescription)
        }
    }

    private func failureSnapshot(_ message: String) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: .alicloud,
            fiveHour: UsageWindow(kind: .fiveHour, usedPercentage: nil, resetsAt: nil, message: message),
            weekly: UsageWindow(kind: .weekly, usedPercentage: nil, resetsAt: nil, message: message),
            detail: nil
        )
    }

    private func date(fromMilliseconds value: Double?) -> Date? {
        guard let value, value > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: value / 1_000)
    }

    // MARK: - Live requests

    static let gatewayURL = "https://bailian-singapore-cs.alibabacloud.com/data/api.json"
    static let usageAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"
    static let subscriptionAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription"

    static func liveFetchUsage(with ticket: String) async throws -> AliCloudUsage {
        let payload = try await gatewayPayload(
            request: gatewayRequest(api: usageAPI, data: [:], ticket: ticket)
        )
        return AliCloudUsage(
            weeklyFraction: flexibleDouble(payload["per1WeekPercentage"]),
            weeklyResetTime: flexibleDouble(payload["per1WeekResetTime"])
        )
    }

    static func liveFetchSubscription(with ticket: String) async throws -> AliCloudSubscription {
        let payload = try await gatewayPayload(
            request: gatewayRequest(api: subscriptionAPI, data: ["queryInstanceInfoRequest": [:]], ticket: ticket)
        )
        return AliCloudSubscription(
            specCode: payload["specCode"] as? String,
            remainingDays: flexibleDouble(payload["remainingDays"]).map { Int($0) }
        )
    }

    /// The console wraps every backend call in the same envelope: the target
    /// API name plus a `Data` object carrying the caller's account context.
    static func gatewayRequest(api: String, data: [String: Any], ticket: String) -> URLRequest {
        var components = URLComponents(string: gatewayURL)!
        components.queryItems = [
            URLQueryItem(name: "action", value: "IntlBroadScopeAspnGateway"),
            URLQueryItem(name: "product", value: "sfm_bailian"),
            URLQueryItem(name: "api", value: api),
        ]

        var payload = data
        payload["cornerstoneParam"] = ["switchUserType": 3]
        let params = try! JSONSerialization.data(withJSONObject: ["Api": api, "V": "1.0", "Data": payload])

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "params", value: String(decoding: params, as: UTF8.self)),
            URLQueryItem(name: "region", value: "ap-southeast-1"),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        request.setValue(
            "login_aliyunid_ticket=\(ticket.trimmingCharacters(in: .whitespacesAndNewlines))",
            forHTTPHeaderField: "Cookie"
        )
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TokenWatch", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func gatewayPayload(request: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AliCloudError.invalidResponse("AliCloud console request failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw AliCloudError.invalidResponse("AliCloud console returned an invalid response.")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw AliCloudError.invalidResponse("AliCloud console returned HTTP \(http.statusCode).")
        }
        return try unwrapGatewayEnvelope(data)
    }

    /// Unwrap `data.DataV2.data.data`, translating the gateway's in-band errors.
    static func unwrapGatewayEnvelope(_ data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outer = root["data"] as? [String: Any] else {
            throw AliCloudError.invalidResponse("AliCloud console response could not be read.")
        }
        if let errorCode = outer["errorCode"] as? String, !errorCode.isEmpty {
            if errorCode.contains("NotLogined") || errorCode.contains("NeedLogin") {
                throw AliCloudError.sessionExpired
            }
            throw AliCloudError.invalidResponse("AliCloud console returned \(errorCode).")
        }
        guard let dataV2 = outer["DataV2"] as? [String: Any],
              let inner = dataV2["data"] as? [String: Any],
              let payload = inner["data"] as? [String: Any] else {
            throw AliCloudError.invalidResponse("AliCloud console response could not be read.")
        }
        return payload
    }

    private static func flexibleDouble(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }
}

struct AliCloudCredentialLoader: Sendable {
    static let cookieName = "login_aliyunid_ticket"

    private let homeDirectory: URL
    private let environment: [String: String]

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    /// An explicit ticket wins; otherwise the cookie is lifted from Muon's
    /// session snapshots, which persist HttpOnly session cookies as plists.
    func loadTicket() -> String? {
        if let ticket = Self.trimmed(environment["ALICLOUD_CONSOLE_TICKET"]) {
            return ticket
        }
        if let ticket = loadFromDotEnv() {
            return ticket
        }
        return loadFromMuonSessions()
    }

    var muonSessionsDirectory: URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/Muon/website-sessions", isDirectory: true)
    }

    private func loadFromMuonSessions() -> String? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: muonSessionsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }
        for file in files where file.pathExtension == "plist" {
            guard let data = try? Data(contentsOf: file),
                  let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let cookies = root["cookies"] as? [[String: Any]] else {
                continue
            }
            for cookie in cookies {
                guard cookie["Name"] as? String == Self.cookieName,
                      let domain = cookie["Domain"] as? String,
                      domain.hasSuffix("alibabacloud.com"),
                      let value = Self.trimmed(cookie["Value"] as? String) else {
                    continue
                }
                return value
            }
        }
        return nil
    }

    private func loadFromDotEnv() -> String? {
        let url = homeDirectory.appendingPathComponent(".env")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        for rawLine in contents.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            }
            guard !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else {
                continue
            }
            guard line[..<separator].trimmingCharacters(in: .whitespaces) == "ALICLOUD_CONSOLE_TICKET" else {
                continue
            }
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
            return Self.trimmed(String(value))
        }
        return nil
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct AliCloudAPIClient: Sendable {
    let fetchUsage: @Sendable (String) async throws -> AliCloudUsage
    let fetchSubscription: @Sendable (String) async throws -> AliCloudSubscription

    init(
        fetchUsage: @escaping @Sendable (String) async throws -> AliCloudUsage = AliCloudProbe.liveFetchUsage(with:),
        fetchSubscription: @escaping @Sendable (String) async throws -> AliCloudSubscription = AliCloudProbe.liveFetchSubscription(with:)
    ) {
        self.fetchUsage = fetchUsage
        self.fetchSubscription = fetchSubscription
    }
}

struct AliCloudUsage: Sendable, Equatable {
    /// Fraction of the 7-day credit quota used, 0 to 1.
    let weeklyFraction: Double?
    /// Epoch milliseconds when the 7-day window resets.
    let weeklyResetTime: Double?
}

struct AliCloudSubscription: Sendable, Equatable {
    let specCode: String?
    let remainingDays: Int?

    var detail: String? {
        var parts: [String] = []
        if let specCode, !specCode.isEmpty {
            parts.append("\(specCode.prefix(1).uppercased() + specCode.dropFirst()) plan")
        }
        if let remainingDays {
            parts.append("\(remainingDays) days left")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum AliCloudError: LocalizedError, Sendable, Equatable {
    case credentialsNotFound
    case sessionExpired
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .credentialsNotFound:
            return "AliCloud credentials not found. Sign in to the Model Studio console in Muon or set ALICLOUD_CONSOLE_TICKET."
        case .sessionExpired:
            return "AliCloud session expired. Sign in to the Model Studio console again."
        case .invalidResponse(let message):
            return message
        }
    }
}
