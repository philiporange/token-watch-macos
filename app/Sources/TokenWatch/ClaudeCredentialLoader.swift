import Foundation

struct ClaudeOAuthCredentials: Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Double?
    var subscriptionType: String?
}

enum ClaudeCredentialSource: Sendable, Equatable {
    case file
    case keychain
    case environment
}

enum ClaudeCredentialLoadIssue: Error, Sendable, Equatable {
    case keychainAccessDenied
    case keychainFailure(String)

    var message: String {
        switch self {
        case .keychainAccessDenied:
            return "Claude Keychain access denied."
        case let .keychainFailure(message):
            return message
        }
    }
}

struct ClaudeCredentialResult: @unchecked Sendable {
    var oauth: ClaudeOAuthCredentials
    let source: ClaudeCredentialSource
    var fullData: [String: Any]
}

struct ClaudeCredentialResolution {
    let credentials: ClaudeCredentialResult?
    let issue: ClaudeCredentialLoadIssue?
}

struct ClaudeCredentialLoader {
    private let homeDirectory: URL
    private let environment: [String: String]
    private let keychainService: String
    private let keychainLoadOverride: Result<ClaudeCredentialResult?, ClaudeCredentialLoadIssue>?
    private let keychainSaveOverride: (@Sendable (ClaudeCredentialResult) -> Void)?

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychainService: String = "Claude Code-credentials",
        keychainLoadOverride: Result<ClaudeCredentialResult?, ClaudeCredentialLoadIssue>? = nil,
        keychainSaveOverride: (@Sendable (ClaudeCredentialResult) -> Void)? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.keychainService = keychainService
        self.keychainLoadOverride = keychainLoadOverride
        self.keychainSaveOverride = keychainSaveOverride
    }

    func resolveCredentials() -> ClaudeCredentialResolution {
        if let credentials = loadFileCredentials() {
            return ClaudeCredentialResolution(credentials: credentials, issue: nil)
        }

        var keychainIssue: ClaudeCredentialLoadIssue?
        switch loadKeychainCredentials() {
        case let .success(credentials):
            if let credentials {
                return ClaudeCredentialResolution(credentials: credentials, issue: nil)
            }
        case let .failure(issue):
            keychainIssue = issue
        }

        if let credentials = loadEnvironmentCredentials() {
            return ClaudeCredentialResolution(credentials: credentials, issue: nil)
        }

        return ClaudeCredentialResolution(credentials: nil, issue: keychainIssue)
    }

    func loadCredentials() -> ClaudeCredentialResult? {
        resolveCredentials().credentials
    }

    func needsRefresh(_ oauth: ClaudeOAuthCredentials) -> Bool {
        guard let expiresAt = oauth.expiresAt else {
            return true
        }

        let nowInMilliseconds = Date().timeIntervalSince1970 * 1_000
        return nowInMilliseconds + 5 * 60 * 1_000 >= expiresAt
    }

    func saveCredentials(_ result: ClaudeCredentialResult) {
        var updatedResult = result
        updatedResult.fullData["claudeAiOauth"] = oauthData(for: result.oauth)

        switch result.source {
        case .environment:
            return
        case .file:
            saveToFile(updatedResult.fullData)
        case .keychain:
            if let keychainSaveOverride {
                keychainSaveOverride(updatedResult)
            } else {
                saveToKeychain(updatedResult.fullData)
            }
        }
    }

    func mapKeychainError(
        _ error: ProcessRunnerError
    ) -> Result<ClaudeCredentialResult?, ClaudeCredentialLoadIssue> {
        guard case let .terminated(_, output) = error else {
            return .failure(.keychainFailure(error.localizedDescription))
        }

        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedOutput = trimmedOutput.lowercased()

        if lowercasedOutput.contains("could not be found in the keychain") ||
            lowercasedOutput.contains("item could not be found") {
            return .success(nil)
        }

        if lowercasedOutput.contains("user interaction is not allowed") ||
            lowercasedOutput.contains("authorization was denied") ||
            lowercasedOutput.contains("user canceled") ||
            lowercasedOutput.contains("user cancelled") {
            return .failure(.keychainAccessDenied)
        }

        if trimmedOutput.isEmpty {
            return .failure(.keychainFailure("Claude Keychain lookup failed."))
        }

        return .failure(.keychainFailure("Claude Keychain lookup failed: \(trimmedOutput)"))
    }

    private var credentialsFileURL: URL {
        homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent(".credentials.json", isDirectory: false)
    }

    private func loadFileCredentials() -> ClaudeCredentialResult? {
        guard let data = try? Data(contentsOf: credentialsFileURL) else {
            return nil
        }

        return parseCredentials(data: data, source: .file)
    }

    private func loadKeychainCredentials() -> Result<ClaudeCredentialResult?, ClaudeCredentialLoadIssue> {
        if let keychainLoadOverride {
            return keychainLoadOverride
        }

        do {
            let output = try ProcessRunner.runSync(
                executable: "/usr/bin/security",
                arguments: ["find-generic-password", "-s", keychainService, "-w"],
                input: nil,
                timeout: nil,
                currentDirectory: nil
            )

            return .success(parseCredentials(data: Data(output.utf8), source: .keychain))
        } catch let error as ProcessRunnerError {
            return mapKeychainError(error)
        } catch {
            return .failure(.keychainFailure(error.localizedDescription))
        }
    }

    private func loadEnvironmentCredentials() -> ClaudeCredentialResult? {
        guard let rawToken = environment["CLAUDE_CODE_OAUTH_TOKEN"] else {
            return nil
        }

        let accessToken = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else {
            return nil
        }

        return ClaudeCredentialResult(
            oauth: ClaudeOAuthCredentials(
                accessToken: accessToken,
                refreshToken: nil,
                expiresAt: nil,
                subscriptionType: nil
            ),
            source: .environment,
            fullData: [:]
        )
    }

    private func parseCredentials(
        data: Data,
        source: ClaudeCredentialSource
    ) -> ClaudeCredentialResult? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let fullData = object as? [String: Any],
              let oauthData = fullData["claudeAiOauth"] as? [String: Any],
              let rawAccessToken = oauthData["accessToken"] as? String else {
            return nil
        }

        let accessToken = rawAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else {
            return nil
        }

        let refreshToken: String?
        if let rawRefreshToken = oauthData["refreshToken"] {
            guard let string = rawRefreshToken as? String else {
                return nil
            }

            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            refreshToken = trimmed.isEmpty ? nil : trimmed
        } else {
            refreshToken = nil
        }

        let expiresAt: Double?
        if let rawExpiresAt = oauthData["expiresAt"] {
            guard let parsedExpiresAt = parseExpiresAt(rawExpiresAt) else {
                return nil
            }

            expiresAt = parsedExpiresAt
        } else {
            expiresAt = nil
        }

        let subscriptionType: String?
        if let rawSubscriptionType = oauthData["subscriptionType"] {
            guard let string = rawSubscriptionType as? String else {
                return nil
            }

            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            subscriptionType = trimmed.isEmpty ? nil : trimmed
        } else {
            subscriptionType = nil
        }

        return ClaudeCredentialResult(
            oauth: ClaudeOAuthCredentials(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: expiresAt,
                subscriptionType: subscriptionType
            ),
            source: source,
            fullData: fullData
        )
    }

    private func parseExpiresAt(_ value: Any) -> Double? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let number = Double(trimmed), number.isFinite else {
                return nil
            }

            return number
        }

        guard let number = value as? NSNumber,
              String(cString: number.objCType) != "c",
              number.doubleValue.isFinite else {
            return nil
        }

        return number.doubleValue
    }

    private func oauthData(for oauth: ClaudeOAuthCredentials) -> [String: Any] {
        var data: [String: Any] = ["accessToken": oauth.accessToken]

        if let refreshToken = oauth.refreshToken {
            data["refreshToken"] = refreshToken
        }
        if let expiresAt = oauth.expiresAt {
            data["expiresAt"] = expiresAt
        }
        if let subscriptionType = oauth.subscriptionType {
            data["subscriptionType"] = subscriptionType
        }

        return data
    }

    private func saveToFile(_ fullData: [String: Any]) {
        do {
            let parentDirectory = credentialsFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parentDirectory,
                withIntermediateDirectories: true
            )

            let data = try JSONSerialization.data(
                withJSONObject: fullData,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: credentialsFileURL, options: .atomic)
        } catch {
            // Credential persistence is best-effort.
        }
    }

    private func saveToKeychain(_ fullData: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: fullData,
            options: [.prettyPrinted, .sortedKeys]
        ),
        let password = String(data: data, encoding: .utf8) else {
            return
        }

        _ = try? ProcessRunner.runSync(
            executable: "/usr/bin/security",
            arguments: ["delete-generic-password", "-s", keychainService],
            input: nil,
            timeout: 5,
            currentDirectory: nil
        )

        _ = try? ProcessRunner.runSync(
            executable: "/usr/bin/security",
            arguments: ["add-generic-password", "-s", keychainService, "-w", password],
            input: nil,
            timeout: 5,
            currentDirectory: nil
        )
    }
}
