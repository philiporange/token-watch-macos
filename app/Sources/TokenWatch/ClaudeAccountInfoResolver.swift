import Foundation

struct ClaudeAccountInfo: Sendable, Equatable {
    let email: String?
    let displayName: String?
    let organizationName: String?
}

struct ClaudeAccountInfoResolver {
    private let configURL: URL

    init(configURL: URL? = nil) {
        if let configURL = configURL {
            self.configURL = configURL
        } else {
            let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
            self.configURL = homeDirectory.appendingPathComponent(".claude.json")
        }
    }

    func resolve() -> ClaudeAccountInfo? {
        guard let data = try? Data(contentsOf: configURL) else {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let oauthAccount = json["oauthAccount"] as? [String: Any] else {
            return nil
        }

        let email = oauthAccount["emailAddress"] as? String
        let displayName = oauthAccount["displayName"] as? String
        let organizationName = oauthAccount["organizationName"] as? String

        // Return nil if all three fields are absent
        if email == nil && displayName == nil && organizationName == nil {
            return nil
        }

        return ClaudeAccountInfo(
            email: email,
            displayName: displayName,
            organizationName: organizationName
        )
    }
}
