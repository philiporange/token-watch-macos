import Foundation
import Testing
@testable import TokenWatch

private actor AuthRetryState {
    private(set) var usageCalls = 0
    private(set) var refreshCalls = 0
    func nextUsageCall() -> Int { usageCalls += 1; return usageCalls }
    func recordRefresh() { refreshCalls += 1 }
}

@Suite struct ClaudeProbeTests {

    // MARK: - Helpers

    private func writeCredentialsFile(home: URL, refreshToken: String? = "RT", expiresInSeconds: Double = 86_400) throws {
        let dir = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var oauth: [String: Any] = [
            "accessToken": "AT",
            "expiresAt": (Date().timeIntervalSince1970 + expiresInSeconds) * 1000,
            "subscriptionType": "claude_max",
        ]
        if let refreshToken { oauth["refreshToken"] = refreshToken }
        let data = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
        try data.write(to: dir.appendingPathComponent(".credentials.json"))
    }

    private func writeAccountInfo(home: URL) throws -> ClaudeAccountInfoResolver {
        let url = home.appendingPathComponent(".claude.json")
        try #"{"oauthAccount":{"displayName":"Dee","emailAddress":"e@x.com","organizationName":"Org"}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        return ClaudeAccountInfoResolver(configURL: url)
    }

    private func loader(home: URL, environment: [String: String] = [:]) -> ClaudeCredentialLoader {
        ClaudeCredentialLoader(homeDirectory: home, environment: environment, keychainLoadOverride: .success(nil))
    }

    // MARK: - Success

    @Test func successBuildsSnapshot() async throws {
        let home = try makeTemporaryDirectory()
        try writeCredentialsFile(home: home)
        let resolver = try writeAccountInfo(home: home)

        let usage = ClaudeUsageResponse(
            fiveHour: ClaudeQuotaData(utilization: 12, resetsAt: "2026-01-01T00:00:00Z"),
            sevenDay: ClaudeQuotaData(utilization: 34, resetsAt: "2026-01-08T00:00:00Z"),
            limits: [ClaudeLimit(kind: "weekly_scoped", percent: 50, resetsAt: "2026-01-08T00:00:00Z", modelName: "Fable", isActive: true)]
        )
        let client = ClaudeAPIClient(
            fetchStatus: { ClaudeAuthStatus(loggedIn: true) },
            refreshToken: { creds, _ in creds },
            fetchUsage: { _ in usage }
        )
        let probe = ClaudeProbe(credentialLoader: loader(home: home), accountInfoResolver: resolver, apiClient: client)
        let snap = await probe.fetch()

        #expect(snap.fiveHour.usedPercentage == 12)
        #expect(snap.weekly.usedPercentage == 34)
        #expect(snap.modelWindows.count == 1)
        #expect(snap.modelWindows.first?.window.kind == .modelWeekly)
        #expect(snap.modelWindows.first?.isActive == true)
        #expect(snap.modelWindows.first?.modelName == "Fable")
        #expect(snap.detail?.contains("Max") == true)
    }

    // MARK: - modelScopedLimits

    @Test func modelScopedLimitsFilterAndSort() {
        let response = ClaudeUsageResponse(
            fiveHour: nil,
            sevenDay: nil,
            limits: [
                ClaudeLimit(kind: "weekly_scoped", percent: 20, resetsAt: nil, modelName: "GPT", isActive: false),
                ClaudeLimit(kind: "weekly_scoped", percent: 10, resetsAt: nil, modelName: "Fable", isActive: false),
                ClaudeLimit(kind: "five_hour", percent: 5, resetsAt: nil, modelName: "X", isActive: false),
                ClaudeLimit(kind: "weekly_scoped", percent: nil, resetsAt: nil, modelName: "Y", isActive: false),
                ClaudeLimit(kind: "weekly_scoped", percent: 5, resetsAt: nil, modelName: "", isActive: false),
            ]
        )
        let scoped = response.modelScopedLimits
        #expect(scoped.count == 2)
        #expect(scoped.first?.modelName == "Fable")
    }

    // MARK: - Auth-failure retry

    @Test func authFailureRetriesAndSucceeds() async throws {
        let home = try makeTemporaryDirectory()
        try writeCredentialsFile(home: home)
        let resolver = try writeAccountInfo(home: home)
        let state = AuthRetryState()

        let usage = ClaudeUsageResponse(
            fiveHour: ClaudeQuotaData(utilization: 20, resetsAt: nil),
            sevenDay: ClaudeQuotaData(utilization: 40, resetsAt: nil),
            limits: []
        )
        let client = ClaudeAPIClient(
            fetchStatus: { ClaudeAuthStatus(loggedIn: true) },
            refreshToken: { creds, _ in await state.recordRefresh(); return creds },
            fetchUsage: { _ in
                let n = await state.nextUsageCall()
                if n == 1 { throw ProcessRunnerError.invalidResponse("Claude authentication failed.") }
                return usage
            }
        )
        let probe = ClaudeProbe(credentialLoader: loader(home: home), accountInfoResolver: resolver, apiClient: client)
        let snap = await probe.fetch()

        #expect(snap.fiveHour.usedPercentage == 20)
        #expect(await state.refreshCalls == 1)
    }

    @Test func environmentSourceDoesNotRetry() async throws {
        let home = try makeTemporaryDirectory()
        let resolver = try writeAccountInfo(home: home)
        let state = AuthRetryState()

        let client = ClaudeAPIClient(
            fetchStatus: { ClaudeAuthStatus(loggedIn: true) },
            refreshToken: { creds, _ in await state.recordRefresh(); return creds },
            fetchUsage: { _ in throw ProcessRunnerError.invalidResponse("Claude authentication failed.") }
        )
        let envLoader = loader(home: home, environment: ["CLAUDE_CODE_OAUTH_TOKEN": "envtok"])
        let probe = ClaudeProbe(credentialLoader: envLoader, accountInfoResolver: resolver, apiClient: client)
        let snap = await probe.fetch()

        #expect(snap.fiveHour.usedPercentage == nil)
        #expect(snap.fiveHour.message?.contains("authentication failed") == true)
        #expect(await state.refreshCalls == 0)
    }

    // MARK: - No credentials

    @Test func noCredentialsLoggedIn() async throws {
        let home = try makeTemporaryDirectory()
        let resolver = try writeAccountInfo(home: home)
        let client = ClaudeAPIClient(
            fetchStatus: { ClaudeAuthStatus(loggedIn: true) },
            refreshToken: { creds, _ in creds },
            fetchUsage: { _ in throw ProcessRunnerError.invalidResponse("unused") }
        )
        let probe = ClaudeProbe(credentialLoader: loader(home: home), accountInfoResolver: resolver, apiClient: client)
        let snap = await probe.fetch()
        #expect(snap.fiveHour.message == "Claude is logged in, but credentials could not be read from file, Keychain, or environment.")
    }

    @Test func noCredentialsNotLoggedIn() async throws {
        let home = try makeTemporaryDirectory()
        let resolver = try writeAccountInfo(home: home)
        let client = ClaudeAPIClient(
            fetchStatus: { ClaudeAuthStatus(loggedIn: false) },
            refreshToken: { creds, _ in creds },
            fetchUsage: { _ in throw ProcessRunnerError.invalidResponse("unused") }
        )
        let probe = ClaudeProbe(credentialLoader: loader(home: home), accountInfoResolver: resolver, apiClient: client)
        let snap = await probe.fetch()
        #expect(snap.fiveHour.message == "Claude credentials not found.")
    }

    @Test func noCredentialsStatusThrows() async throws {
        let home = try makeTemporaryDirectory()
        let resolver = try writeAccountInfo(home: home)
        let client = ClaudeAPIClient(
            fetchStatus: { throw ProcessRunnerError.invalidResponse("boom") },
            refreshToken: { creds, _ in creds },
            fetchUsage: { _ in throw ProcessRunnerError.invalidResponse("unused") }
        )
        let probe = ClaudeProbe(credentialLoader: loader(home: home), accountInfoResolver: resolver, apiClient: client)
        let snap = await probe.fetch()
        #expect(snap.fiveHour.message == "Claude credentials not found.")
    }

    // MARK: - Helper methods

    @Test func parseISODate() {
        let probe = ClaudeProbe()
        #expect(probe.parseISODate("2026-01-01T00:00:00.000Z") != nil)
        #expect(probe.parseISODate("2026-01-01T00:00:00Z") != nil)
        #expect(probe.parseISODate(nil) == nil)
    }

    @Test func formatSubscriptionType() {
        let probe = ClaudeProbe()
        #expect(probe.formatSubscriptionType("claude_max") == "Max")
        #expect(probe.formatSubscriptionType("max") == "Max")
        #expect(probe.formatSubscriptionType("claude_pro") == "Pro")
        #expect(probe.formatSubscriptionType("api") == "API")
        #expect(probe.formatSubscriptionType("something") == "something")
    }

    @Test func detailText() {
        let probe = ClaudeProbe()
        let result = ClaudeCredentialResult(
            oauth: ClaudeOAuthCredentials(accessToken: "x", refreshToken: nil, expiresAt: nil, subscriptionType: "claude_max"),
            source: .file,
            fullData: [:]
        )
        let info = ClaudeAccountInfo(email: "e@x.com", displayName: "Dee", organizationName: nil)
        #expect(probe.detailText(from: result, accountInfo: info) == "Max · Dee")

        let bare = ClaudeCredentialResult(
            oauth: ClaudeOAuthCredentials(accessToken: "x", refreshToken: nil, expiresAt: nil, subscriptionType: nil),
            source: .file,
            fullData: [:]
        )
        #expect(probe.detailText(from: bare, accountInfo: nil) == nil)
    }

    @Test func shouldRetryAfterAuthenticationError() {
        let probe = ClaudeProbe()
        #expect(probe.shouldRetryAfterAuthenticationError(.invalidResponse("Claude authentication failed.")) == true)
        #expect(probe.shouldRetryAfterAuthenticationError(.invalidResponse("other")) == false)
        #expect(probe.shouldRetryAfterAuthenticationError(.executableNotFound("claude")) == false)
    }
}
