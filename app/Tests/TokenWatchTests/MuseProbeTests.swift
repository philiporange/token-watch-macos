import Foundation
import Testing
@testable import TokenWatch

struct MuseProbeTests {
    @Test
    func credentialLoaderPrefersAuthFileTokenAndHonorsXDGConfigHome() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent("xdg/muse", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try """
        {"schema_version": 2, "providers": {"meta": {"mechanism": "oauth", "storage": "file", "access_token": " file-token "}}}
        """.write(to: config.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)

        let loader = MuseCredentialLoader(
            homeDirectory: home,
            environment: ["XDG_CONFIG_HOME": home.appendingPathComponent("xdg").path],
            keychainLoadOverride: .success(#"{"access_token": "keychain-token"}"#)
        )

        #expect(try loader.loadAccessToken() == "file-token")
    }

    @Test
    func credentialLoaderFallsBackToKeychainSecret() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".config/muse", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try """
        {"schema_version": 2, "providers": {"meta": {"mechanism": "oauth", "storage": "keychain"}}}
        """.write(to: config.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)

        let loader = MuseCredentialLoader(
            homeDirectory: home,
            environment: [:],
            keychainLoadOverride: .success(
                #"{"secret_schema_version": 1, "api_key": "LLM|ignored", "access_token": "dca:keychain-token"}"#
            )
        )

        #expect(try loader.loadAccessToken() == "dca:keychain-token")

        let missing = MuseCredentialLoader(homeDirectory: home, environment: [:], keychainLoadOverride: .success(nil))
        #expect(throws: MuseError.credentialsNotFound) {
            try missing.loadAccessToken()
        }

        let denied = MuseCredentialLoader(
            homeDirectory: home,
            environment: [:],
            keychainLoadOverride: .failure(.keychainAccessDenied)
        )
        #expect(throws: MuseError.keychainAccessDenied) {
            try denied.loadAccessToken()
        }
    }

    @Test
    func accountRequestPostsEmptyJSONWithBearerToken() {
        let request = MuseProbe.accountRequest(with: "  dca:token  ")

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.meta.ai/muse-code/key")
        #expect(request.httpBody == Data("{}".utf8))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer dca:token")
        #expect(request.value(forHTTPHeaderField: "x-api-version") == "1.0.0")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test
    func fetchMapsWindowAndWeeklyUsageToFiveHourAndWeeklyWindows() async throws {
        let probe = MuseProbe(
            credentialLoader: MuseCredentialLoader(
                homeDirectory: URL(fileURLWithPath: "/nonexistent"),
                environment: [:],
                keychainLoadOverride: .success(#"{"access_token": "dca:token"}"#)
            ),
            apiClient: MuseAPIClient { token in
                #expect(token == "dca:token")
                return MuseAccountResponse(
                    subscriptionTierName: "Muse Code High Usage",
                    subscriptionUsage: MuseSubscriptionUsage(
                        window: MuseUsageWindow(usedPercent: 12, resetsAt: 1_789_623_043, windowDurationMinutes: 300),
                        weekly: MuseUsageWindow(usedPercent: 34, resetsAt: 1_789_948_800)
                    )
                )
            }
        )

        let snapshot = await probe.fetch()

        #expect(snapshot.provider == .muse)
        #expect(snapshot.fiveHour.kind == .fiveHour)
        #expect(snapshot.fiveHour.usedPercentage == 12)
        #expect(snapshot.fiveHour.resetsAt == Date(timeIntervalSince1970: 1_789_623_043))
        #expect(snapshot.weekly.kind == .weekly)
        #expect(snapshot.weekly.usedPercentage == 34)
        #expect(snapshot.weekly.resetsAt == Date(timeIntervalSince1970: 1_789_948_800))
        #expect(snapshot.detail == "Muse Code High Usage")
    }

    @Test
    func fetchReportsAuthenticationFailureInBothWindows() async {
        let probe = MuseProbe(
            credentialLoader: MuseCredentialLoader(
                homeDirectory: URL(fileURLWithPath: "/nonexistent"),
                environment: [:],
                keychainLoadOverride: .success(#"{"access_token": "dca:token"}"#)
            ),
            apiClient: MuseAPIClient { _ in throw MuseError.authenticationFailed }
        )

        let snapshot = await probe.fetch()

        #expect(snapshot.fiveHour.usedPercentage == nil)
        #expect(snapshot.fiveHour.message == "Muse authentication failed. Run muse login again.")
        #expect(snapshot.weekly.message == snapshot.fiveHour.message)
    }

    @Test
    func accountResponseDecodesLiveShapeAndToleratesStringNumbers() throws {
        let data = Data("""
        {
          "api_key": "LLM|secret",
          "base_url": "https://api.meta.ai/v1",
          "is_subs_active": true,
          "subs_tier_id": "27681527378179523",
          "subs_tier_name": "Muse Code High Usage",
          "subs_usage": {
            "window": {"used_percent": "7.5", "window_duration_mins": 300, "resets_at": 1789623043},
            "weekly": {"used_percent": 0, "resets_at": "1789948800"},
            "tier": "27681527378179523"
          }
        }
        """.utf8)

        let response = try JSONDecoder().decode(MuseAccountResponse.self, from: data)

        #expect(response.subscriptionTierName == "Muse Code High Usage")
        #expect(response.subscriptionUsage?.window?.usedPercent == 7.5)
        #expect(response.subscriptionUsage?.window?.windowDurationMinutes == 300)
        #expect(response.subscriptionUsage?.weekly?.usedPercent == 0)
        #expect(response.subscriptionUsage?.weekly?.resetsAt == 1_789_948_800)
    }
}
