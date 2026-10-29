import Foundation

public enum ConnectionError: LocalizedError, Equatable {
    case invalidAddress, rejectedKey, badResponse, server(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: "Enter your Mac’s address, such as sandford.local:8037."
        case .rejectedKey: "The pairing key was not accepted. Copy the current key from Token Watch on your Mac."
        case .badResponse: "This address did not return Token Watch usage. Check the address and port."
        case .server(let status): "Your Mac returned an error (\(status)). Try again shortly."
        }
    }
}

public struct MacConnection: Codable, Equatable, Sendable {
    public let address: String
    public let token: String

    public init(address: String, token: String) throws {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "http://" + text }
        guard var parts = URLComponents(string: text),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, !host.contains(where: \.isWhitespace),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              ["", "/", "/usage"].contains(parts.path),
              parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw ConnectionError.invalidAddress
        }
        parts.path = ""
        if parts.port == nil && parts.scheme == "http" { parts.port = 8037 }
        guard let normalized = parts.url?.absoluteString else { throw ConnectionError.invalidAddress }
        self.address = normalized
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var host: String { URL(string: address)?.host ?? address }
    public var displayName: String { host.replacingOccurrences(of: ".local", with: "").capitalized }

    public func request(refresh: Bool = false) throws -> URLRequest {
        guard let url = URL(string: address)?.appendingPathComponent(refresh ? "refresh" : "usage") else { throw ConnectionError.invalidAddress }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: refresh ? 60 : 12)
        if refresh {
            request.httpMethod = "POST"
            request.httpBody = Data()
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    public static func routeKey(for providerName: String) -> String {
        providerName.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    public func applyResetRequest(providerRouteKey: String, resetID: String) throws -> URLRequest {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard var parts = URLComponents(string: address),
              let provider = providerRouteKey.addingPercentEncoding(withAllowedCharacters: allowed),
              let reset = resetID.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw ConnectionError.invalidAddress
        }
        parts.percentEncodedPath = "/resets/\(provider)/\(reset)/apply"
        guard let url = parts.url else { throw ConnectionError.invalidAddress }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.httpBody = Data()
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

}

public enum UsageClient {
    public static func fetch(_ connection: MacConnection, refresh: Bool = false, session: URLSession = .shared) async throws -> (UsageSnapshot, Data) {
        let (data, response) = try await session.data(for: connection.request(refresh: refresh))
        return (try decode(data, response: response), data)
    }

    public static func applyReset(_ connection: MacConnection, providerRouteKey: String, resetID: String,
                                  session: URLSession = .shared) async throws -> BankedResetApplyResult {
        let request = try connection.applyResetRequest(providerRouteKey: providerRouteKey, resetID: resetID)
        let (data, response) = try await session.data(for: request)
        return try decodeApplyResult(data, response: response)
    }

    public static func decodeApplyResult(_ data: Data, response: URLResponse) throws -> BankedResetApplyResult {
        guard let response = response as? HTTPURLResponse else { throw ConnectionError.badResponse }
        if response.statusCode == 401 || response.statusCode == 403 { throw ConnectionError.rejectedKey }
        guard [200, 404, 409, 502].contains(response.statusCode) else {
            throw ConnectionError.server(response.statusCode)
        }
        do { return try UsageSnapshot.makeDecoder().decode(BankedResetApplyResult.self, from: data) }
        catch { throw ConnectionError.badResponse }
    }

    public static func decode(_ data: Data, response: URLResponse) throws -> UsageSnapshot {
        guard let response = response as? HTTPURLResponse else { throw ConnectionError.badResponse }
        if response.statusCode == 401 || response.statusCode == 403 { throw ConnectionError.rejectedKey }
        guard response.statusCode == 200 else { throw ConnectionError.server(response.statusCode) }
        do { return try UsageSnapshot.decode(data) }
        catch { throw ConnectionError.badResponse }
    }
}

public struct BankedResetApplyResult: Codable, Equatable, Sendable {
    public let provider: String
    public let resetID: String
    public let outcome: String
    public let applied: Bool
    public let message: String
    public let usage: ProviderUsage

    enum CodingKeys: String, CodingKey {
        case provider, outcome, applied, message, usage
        case resetID = "reset_id"
    }
}
