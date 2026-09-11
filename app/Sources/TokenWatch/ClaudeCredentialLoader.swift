import Foundation

struct ClaudeOAuthCredentials: Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Double?
    var subscriptionType: String?
    /// Scopes the stored grant was issued with, replayed on refresh so the
    /// rotated token keeps them instead of being silently narrowed.
    var scopes: [String]?
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
        // File and Keychain are collected together rather than short-circuiting on
        // the first hit: a leftover ~/.claude/.credentials.json parses fine but can
        // hold an access token that expired and a refresh token that has already
        // been rotated away, which would otherwise shadow live Keychain credentials.
        var candidates: [ClaudeCredentialResult] = []

        if let credentials = loadFileCredentials() {
            candidates.append(credentials)
        }

        var keychainIssue: ClaudeCredentialLoadIssue?
        switch loadKeychainCredentials() {
        case let .success(credentials):
            if let credentials {
                candidates.append(credentials)
            }
        case let .failure(issue):
            keychainIssue = issue
        }

        if let credentials = freshestCandidate(candidates) {
            return ClaudeCredentialResolution(credentials: credentials, issue: nil)
        }

        if let credentials = loadEnvironmentCredentials() {
            return ClaudeCredentialResolution(credentials: credentials, issue: nil)
        }

        return ClaudeCredentialResolution(credentials: nil, issue: keychainIssue)
    }

    /// The most usable candidate in preference order: the first that still has a
    /// live access token, else the one expiring latest. Candidates are supplied
    /// file-first, so equally-fresh sources keep the file's long-standing priority.
    private func freshestCandidate(
        _ candidates: [ClaudeCredentialResult]
    ) -> ClaudeCredentialResult? {
        if let usable = candidates.first(where: { !needsRefresh($0.oauth) }) {
            return usable
        }

        return candidates.max {
            ($0.oauth.expiresAt ?? -.greatestFiniteMagnitude) <
                ($1.oauth.expiresAt ?? -.greatestFiniteMagnitude)
        }
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
        updatedResult.fullData["claudeAiOauth"] = oauthData(
            for: result.oauth,
            mergingInto: result.fullData["claudeAiOauth"] as? [String: Any] ?? [:]
        )

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

        let scopes = (oauthData["scopes"] as? [Any])?
            .compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return ClaudeCredentialResult(
            oauth: ClaudeOAuthCredentials(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: expiresAt,
                subscriptionType: subscriptionType,
                scopes: (scopes?.isEmpty ?? true) ? nil : scopes
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

    /// Writes the fields this app manages over the stored blob, leaving every other
    /// key untouched. Rebuilding from scratch would drop siblings the Claude CLI
    /// relies on (`refreshTokenExpiresAt`, `rateLimitTier`, and friends).
    private func oauthData(
        for oauth: ClaudeOAuthCredentials,
        mergingInto existing: [String: Any]
    ) -> [String: Any] {
        var data = existing
        data["accessToken"] = oauth.accessToken

        if let refreshToken = oauth.refreshToken {
            data["refreshToken"] = refreshToken
        } else {
            data.removeValue(forKey: "refreshToken")
        }
        if let expiresAt = oauth.expiresAt {
            data["expiresAt"] = expiresAt
        } else {
            data.removeValue(forKey: "expiresAt")
        }
        if let subscriptionType = oauth.subscriptionType {
            data["subscriptionType"] = subscriptionType
        } else {
            data.removeValue(forKey: "subscriptionType")
        }
        if let scopes = oauth.scopes, !scopes.isEmpty {
            data["scopes"] = scopes
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
