import Foundation
import Testing
@testable import TokenWatch

@Suite struct ClaudeCredentialLoaderTests {

    // MARK: - Helpers

    private func writeCredentialsFile(home: URL, json: String) throws {
        let dir = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)
    }

    private func credentialsURL(home: URL) -> URL {
        home.appendingPathComponent(".claude").appendingPathComponent(".credentials.json")
    }

    private func keychainResult() -> ClaudeCredentialResult {
        ClaudeCredentialResult(
            oauth: ClaudeOAuthCredentials(accessToken: "KC", refreshToken: nil, expiresAt: nil, subscriptionType: nil),
            source: .keychain,
            fullData: [:]
        )
    }

    // MARK: - File source wins

    @Test func fileSourceWins() throws {
        let home = try makeTemporaryDirectory()
        try writeCredentialsFile(
            home: home,
            json: #"{"claudeAiOauth":{"accessToken":"AT","refreshToken":"RT","expiresAt":1700000000000,"subscriptionType":"claude_max"}}"#
        )
        let loader = ClaudeCredentialLoader(
            homeDirectory: home,
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "envtok"],
            keychainLoadOverride: .success(keychainResult())
        )
        let result = try #require(loader.loadCredentials())
        #expect(result.source == .file)
        #expect(result.oauth.accessToken == "AT")
        #expect(result.oauth.refreshToken == "RT")
        #expect(result.oauth.expiresAt == 1_700_000_000_000)
        #expect(result.oauth.subscriptionType == "claude_max")
    }

    @Test func fileNumericStringExpiresAt() throws {
        let home = try makeTemporaryDirectory()
        try writeCredentialsFile(
            home: home,
            json: #"{"claudeAiOauth":{"accessToken":"AT","expiresAt":"1700000000000"}}"#
        )
        let loader = ClaudeCredentialLoader(homeDirectory: home, environment: [:], keychainLoadOverride: .success(nil))
        let result = try #require(loader.loadCredentials())
        #expect(result.oauth.expiresAt == 1_700_000_000_000)
    }

    // MARK: - Keychain / environment sources

    @Test func keychainOverrideSuppliesCredentials() throws {
        let home = try makeTemporaryDirectory()
        let loader = ClaudeCredentialLoader(
            homeDirectory: home,
            environment: [:],
            keychainLoadOverride: .success(keychainResult())
        )
        let result = try #require(loader.loadCredentials())
        #expect(result.source == .keychain)
        #expect(result.oauth.accessToken == "KC")
    }

    @Test func environmentUsedWhenFileAndKeychainAbsent() throws {
        let home = try makeTemporaryDirectory()
        let loader = ClaudeCredentialLoader(
            homeDirectory: home,
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "envtok"],
            keychainLoadOverride: .success(nil)
        )
        let result = try #require(loader.loadCredentials())
        #expect(result.source == .environment)
        #expect(result.oauth.accessToken == "envtok")
        #expect(result.oauth.refreshToken == nil)
    }

    @Test func blankEnvironmentTokenIgnored() throws {
        let home = try makeTemporaryDirectory()
        let loader = ClaudeCredentialLoader(
            homeDirectory: home,
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "   "],
            keychainLoadOverride: .success(nil)
        )
        #expect(loader.loadCredentials() == nil)
    }

    // MARK: - resolveCredentials + keychain issue surfacing

    @Test func keychainFailureSurfacedOnlyWhenNoSource() throws {
        let home = try makeTemporaryDirectory()
        let loader = ClaudeCredentialLoader(
            homeDirectory: home,
            environment: [:],
            keychainLoadOverride: .failure(.keychainAccessDenied)
        )
        let resolution = loader.resolveCredentials()
        #expect(resolution.credentials == nil)
        #expect(resolution.issue == .keychainAccessDenied)
    }

    @Test func keychainFailureNotSurfacedWhenFileSucceeds() throws {
        let home = try makeTemporaryDirectory()
        try writeCredentialsFile(home: home, json: #"{"claudeAiOauth":{"accessToken":"AT"}}"#)
        let loader = ClaudeCredentialLoader(
            homeDirectory: home,
            environment: [:],
            keychainLoadOverride: .failure(.keychainAccessDenied)
        )
        let resolution = loader.resolveCredentials()
        #expect(resolution.issue == nil)
        #expect(resolution.credentials?.source == .file)
    }

    @Test func accessDeniedMessage() {
        #expect(ClaudeCredentialLoadIssue.keychainAccessDenied.message == "Claude Keychain access denied.")
    }

    // MARK: - needsRefresh

    @Test func needsRefresh() throws {
        let home = try makeTemporaryDirectory()
        let loader = ClaudeCredentialLoader(homeDirectory: home, environment: [:], keychainLoadOverride: .success(nil))

        let nilExpiry = ClaudeOAuthCredentials(accessToken: "x", refreshToken: nil, expiresAt: nil, subscriptionType: nil)
        #expect(loader.needsRefresh(nilExpiry) == true)

        let nowMs = Date().timeIntervalSince1970 * 1000
        let hourAhead = ClaudeOAuthCredentials(accessToken: "x", refreshToken: nil, expiresAt: nowMs + 3_600_000, subscriptionType: nil)
        #expect(loader.needsRefresh(hourAhead) == false)

        let insideBuffer = ClaudeOAuthCredentials(accessToken: "x", refreshToken: nil, expiresAt: nowMs + 4 * 60_000, subscriptionType: nil)
        #expect(loader.needsRefresh(insideBuffer) == true)
    }

    // MARK: - mapKeychainError

    @Test func mapKeychainErrorNotFound() throws {
        let home = try makeTemporaryDirectory()
        let loader = ClaudeCredentialLoader(homeDirectory: home, environment: [:], keychainLoadOverride: .success(nil))
        switch loader.mapKeychainError(.terminated(1, "The specified item could not be found in the keychain.")) {
        case .success(let value):
            #expect(value == nil)
        case .failure(let issue):
            Issue.record("expected success(nil), got failure \(issue)")
        }
    }

    @Test func mapKeychainErrorAccessDenied() throws {
        let home = try makeTemporaryDirectory()
        let loader = ClaudeCredentialLoader(homeDirectory: home, environment: [:], keychainLoadOverride: .success(nil))
        switch loader.mapKeychainError(.terminated(1, "User interaction is not allowed.")) {
        case .success(let value):
            Issue.record("expected failure, got success \(String(describing: value))")
        case .failure(let issue):
            #expect(issue == .keychainAccessDenied)
        }
    }

    @Test func mapKeychainErrorOther() throws {
        let home = try makeTemporaryDirectory()
        let loader = ClaudeCredentialLoader(homeDirectory: home, environment: [:], keychainLoadOverride: .success(nil))
        switch loader.mapKeychainError(.terminated(1, "boom something bad")) {
        case .success(let value):
            Issue.record("expected failure, got success \(String(describing: value))")
        case .failure(.keychainFailure(let message)):
            #expect(message.contains("boom something bad"))
        case .failure(let issue):
            Issue.record("expected keychainFailure, got \(issue)")
        }
    }

    // MARK: - saveCredentials

    @Test func saveToFilePreservesUnknownKeysAndUpdatesOAuth() throws {
        let home = try makeTemporaryDirectory()
        try writeCredentialsFile(
            home: home,
            json: #"{"claudeAiOauth":{"accessToken":"AT"},"otherKey":"keepme"}"#
        )
        let loader = ClaudeCredentialLoader(homeDirectory: home, environment: [:], keychainLoadOverride: .success(nil))
        var result = try #require(loader.loadCredentials())
        #expect(result.fullData["otherKey"] as? String == "keepme")

        result.oauth.accessToken = "NEW"
        loader.saveCredentials(result)

        let reloaded = try #require(
            ClaudeCredentialLoader(homeDirectory: home, environment: [:], keychainLoadOverride: .success(nil))
                .loadCredentials()
        )
        #expect(reloaded.oauth.accessToken == "NEW")
        #expect(reloaded.fullData["otherKey"] as? String == "keepme")
    }

    @Test func saveEnvironmentSourceWritesNothing() throws {
        let home = try makeTemporaryDirectory()
        let loader = ClaudeCredentialLoader(
            homeDirectory: home,
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "envtok"],
            keychainLoadOverride: .success(nil)
        )
        let result = try #require(loader.loadCredentials())
        #expect(result.source == .environment)
        loader.saveCredentials(result)
        #expect(FileManager.default.fileExists(atPath: credentialsURL(home: home).path) == false)
    }
}
