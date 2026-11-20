import Foundation
import Testing
@testable import TokenWatch

struct GeminiProbeTests {
    @Test
    func credentialLoaderDecodesKeyringBase64AndHeadlessFile() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let payload = """
        {
          "token": {
            "access_token": "agy-access",
            "refresh_token": "agy-refresh",
            "expiry": "2030-01-02T03:04:05Z"
          },
          "auth_method": "consumer"
        }
        """
        let encoded = Data(payload.utf8).base64EncodedString()
        let keychainLoader = AgyCredentialLoader(
            homeDirectory: home,
            environment: [:],
            keychainLoadOverride: .success("go-keyring-base64:\(encoded)")
        )

        let keychainCredential = try keychainLoader.loadCredential()

        #expect(keychainCredential.accessToken == "agy-access")
        #expect(keychainCredential.refreshToken == "agy-refresh")
        #expect(keychainCredential.authMethod == "consumer")
        #expect(keychainCredential.expiry != nil)

        let tokenFile = home.appendingPathComponent("custom-token")
        try payload.write(to: tokenFile, atomically: true, encoding: .utf8)
        let fileLoader = AgyCredentialLoader(
            homeDirectory: home,
            environment: ["AGY_OAUTH_TOKEN_FILE": tokenFile.path],
            keychainLoadOverride: .success(nil)
        )

        #expect(try fileLoader.loadCredential().accessToken == "agy-access")
    }

    @Test
    func internalRequestsUseBearerTokenAndAntigravityMetadata() throws {
        let request = try GeminiProbe.internalRequest(
            host: "daily-cloudcode-pa.googleapis.com",
            method: "loadCodeAssist",
            accessToken: " agy-token ",
            body: ["metadata": ["ideType": "ANTIGRAVITY"]]
        )
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let metadata = try #require(json["metadata"] as? [String: String])

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer agy-token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(metadata["ideType"] == "ANTIGRAVITY")
    }

    @Test
    func quotaDecoderToleratesMissingLabelsAndStringFractions() throws {
        let data = Data("""
        {
          "groups": [{
            "buckets": [{
              "window": "weekly",
              "remainingFraction": "0.75",
              "disabled": false
            }]
          }]
        }
        """.utf8)

        let summary = try JSONDecoder().decode(AgyQuotaSummary.self, from: data)

        #expect(summary.groups[0].displayName == "Model group")
        #expect(summary.groups[0].buckets[0].displayName == "weekly")
        #expect(summary.groups[0].buckets[0].remainingFraction == 0.75)
        #expect(summary.groups[0].buckets[0].kind == .weekly)
    }

    @Test
    func tierNamePrefersPaidTierOverCurrentTier() throws {
        let paid = AgyLoadCodeAssistResponse(
            cloudaicompanionProject: "p",
            currentTier: AgyTier(id: "free-tier", name: "Antigravity"),
            paidTier: AgyTier(id: "g1-pro-tier", name: "Google AI Pro")
        )
        #expect(paid.tierName == "Google AI Pro")

        let free = AgyLoadCodeAssistResponse(
            cloudaicompanionProject: "p",
            currentTier: AgyTier(id: "free-tier", name: "Antigravity"),
            paidTier: nil
        )
        #expect(free.tierName == "free-tier")
    }

    @Test
    func fetchRefreshesExpiredTokenAndMapsRemainingQuotaToUsage() async throws {
        let rawCredential = """
        {"token":{"access_token":"expired","refresh_token":"refresh-me","expiry":"2020-01-01T00:00:00Z"}}
        """
        let reset = "2030-01-02T03:04:05Z"
        let result = AgyQuotaFetchResult(
            summary: AgyQuotaSummary(groups: [
                AgyQuotaGroup(displayName: "GEMINI MODELS", buckets: [
                    AgyQuotaBucket(bucketId: "weekly", displayName: "Weekly Limit", window: "weekly", remainingFraction: 0.9172, resetTime: reset),
                    AgyQuotaBucket(bucketId: "five-hour", displayName: "Five Hour Limit", window: "5h", remainingFraction: 0.9463, resetTime: reset),
                ]),
                AgyQuotaGroup(displayName: "FLASH MODELS", buckets: [
                    AgyQuotaBucket(displayName: "Weekly Limit", window: "weekly", remainingFraction: 0.75, resetTime: reset),
                ]),
            ]),
            tier: "standard-tier",
            host: "daily-cloudcode-pa.googleapis.com"
        )
        let probe = GeminiProbe(
            credentialLoader: AgyCredentialLoader(
                environment: [:],
                keychainLoadOverride: .success(rawCredential)
            ),
            apiClient: AgyAPIClient(
                fetchQuota: { token, _ in
                    #expect(token == "fresh-token")
                    return result
                },
                refreshAccessToken: { refreshToken in
                    #expect(refreshToken == "refresh-me")
                    return "fresh-token"
                }
            )
        )

        let snapshot = await probe.fetch()

        #expect(snapshot.provider == .gemini)
        #expect(abs((snapshot.fiveHour.usedPercentage ?? 0) - 5.37) < 0.0001)
        #expect(abs((snapshot.weekly.usedPercentage ?? 0) - 8.28) < 0.0001)
        #expect(snapshot.fiveHour.resetsAt != nil)
        #expect(snapshot.weekly.resetsAt != nil)
        #expect(snapshot.detail == "GEMINI MODELS · standard-tier")
        #expect(snapshot.modelWindows.count == 1)
        #expect(snapshot.modelWindows[0].modelName == "FLASH MODELS · Weekly Limit")
        #expect(snapshot.modelWindows[0].window.usedPercentage == 25)
    }

    @Test
    func fetchRetriesAuthenticationFailureWithRefreshToken() async {
        actor Attempts {
            var count = 0
            func next() -> Int {
                count += 1
                return count
            }
        }
        let attempts = Attempts()
        let rawCredential = """
        {"token":{"access_token":"stale","refresh_token":"refresh-me","expiry":"2030-01-01T00:00:00Z"}}
        """
        let result = AgyQuotaFetchResult(
            summary: AgyQuotaSummary(groups: [AgyQuotaGroup(displayName: "GEMINI MODELS", buckets: [])]),
            tier: nil,
            host: "daily-cloudcode-pa.googleapis.com"
        )
        let probe = GeminiProbe(
            credentialLoader: AgyCredentialLoader(environment: [:], keychainLoadOverride: .success(rawCredential)),
            apiClient: AgyAPIClient(
                fetchQuota: { token, _ in
                    if await attempts.next() == 1 {
                        #expect(token == "stale")
                        throw AgyError.authenticationFailed
                    }
                    #expect(token == "fresh")
                    return result
                },
                refreshAccessToken: { _ in "fresh" }
            )
        )

        let snapshot = await probe.fetch()

        #expect(snapshot.provider == .gemini)
        #expect(snapshot.fiveHour.message == "No Gemini 5h limit returned.")
    }

    @Test
    func disabledBucketIsUnavailable() async {
        let rawCredential = "{\"access_token\":\"token\"}"
        let result = AgyQuotaFetchResult(
            summary: AgyQuotaSummary(groups: [
                AgyQuotaGroup(displayName: "GEMINI MODELS", buckets: [
                    AgyQuotaBucket(displayName: "Five Hour Limit", window: "5h", remainingFraction: 1, disabled: true),
                ]),
            ]),
            tier: nil,
            host: "daily-cloudcode-pa.googleapis.com"
        )
        let probe = GeminiProbe(
            credentialLoader: AgyCredentialLoader(environment: [:], keychainLoadOverride: .success(rawCredential)),
            apiClient: AgyAPIClient(fetchQuota: { _, _ in result }, refreshAccessToken: { _ in "unused" })
        )

        let snapshot = await probe.fetch()

        #expect(snapshot.fiveHour.usedPercentage == nil)
        #expect(snapshot.fiveHour.message == "Quota disabled.")
    }

    @Test
    func readsBuiltinQuotaAndKeepsModelGroupsSeparate() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let agy = directory.appendingPathComponent("agy")
        let script = """
        #!/bin/sh
        case "$*" in
          "--version") echo 1.5.13 ;;
          "--output-format json -p /usage") cat <<'JSON'
        {"status":"SUCCESS","usage":{"total_tokens":0},"command":{"name":"usage","data":{"groups":[
          {"name":"Claude and GPT models","buckets":[{"id":"3p-weekly","window":"weekly","remaining_fraction":1}]},
          {"name":"Gemini 4 Argon","buckets":[{"id":"gemini-argon-wtu-weekly","name":"Argon Weekly Limit","window":"weekly","remaining_fraction":0}]},
          {"name":"Gemini Models","buckets":[
            {"id":"gemini-weekly","window":"weekly","remaining_fraction":0.9675,"reset_time":"2030-01-02T03:04:05Z"},
            {"id":"gemini-5h","window":"5h","remaining_fraction":1}
          ]}
        ]}}}
        JSON
          ;;
          *) exit 2 ;;
        esac
        """
        try script.write(to: agy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agy.path)
        let raw = #"{"access_token":"token"}"#
        let client = AgyAPIClient(
            readCLIQuota: { await AgyCLIUsage.read(executable: agy.path) },
            fetchQuota: { _, cliSummary in
                AgyQuotaFetchResult(summary: try #require(cliSummary), tier: "Google AI Pro", host: "test")
            },
            refreshAccessToken: { _ in "unused" }
        )
        let probe = GeminiProbe(
            credentialLoader: AgyCredentialLoader(environment: [:], keychainLoadOverride: .success(raw)),
            apiClient: client
        )
        let snapshot = await probe.fetch()
        #expect(abs(try #require(snapshot.weekly.usedPercentage) - 3.25) < 0.0001)
        #expect(snapshot.weekly.resetsAt == ISO8601DateFormatter().date(from: "2030-01-02T03:04:05Z"))
        #expect(snapshot.fiveHour.usedPercentage == 0)
        #expect(snapshot.detail == "Gemini Models · Google AI Pro")
        #expect(snapshot.modelWindows.map(\.modelName) == ["Claude and GPT models · weekly", "Gemini 4 Argon · Argon Weekly Limit"])
        #expect(snapshot.modelWindows.map(\.window.usedPercentage) == [0, 100])

        let noCredential = GeminiProbe(
            credentialLoader: AgyCredentialLoader(homeDirectory: directory, environment: [:], keychainLoadOverride: .success(nil)),
            apiClient: client
        )
        let cliOnly = await noCredential.fetch()
        #expect(cliOnly.weekly.usedPercentage == snapshot.weekly.usedPercentage)
        #expect(cliOnly.detail == "Gemini Models")
    }

    @Test
    func unsupportedCLIIsNeverSentAPrompt() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let agy = directory.appendingPathComponent("agy")
        try """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo 1.1.10; else touch "$0.invoked"; fi
        """.write(to: agy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agy.path)

        #expect(await AgyCLIUsage.read(executable: agy.path) == nil)
        #expect(!FileManager.default.fileExists(atPath: agy.path + ".invoked"))
    }

    @Test
    func tokenFileOverrideKeepsThirdPartyQuotaOutOfGeminiWindows() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenFile = directory.appendingPathComponent("credential")
        try #"{"access_token":"custom"}"#.write(to: tokenFile, atomically: true, encoding: .utf8)
        let result = AgyQuotaFetchResult(
            summary: AgyQuotaSummary(groups: [
                AgyQuotaGroup(displayName: "Claude and GPT models", buckets: [
                    AgyQuotaBucket(bucketId: "3p-weekly", displayName: "Weekly Limit", remainingFraction: 1)
                ])
            ]),
            tier: nil, host: "test"
        )
        let probe = GeminiProbe(
            credentialLoader: AgyCredentialLoader(environment: ["AGY_OAUTH_TOKEN_FILE": tokenFile.path], keychainLoadOverride: .success(nil)),
            apiClient: AgyAPIClient(
                readCLIQuota: { Issue.record("Invoked agy for a custom credential"); return nil },
                fetchQuota: { token, cliSummary in
                    #expect(token == "custom")
                    #expect(cliSummary == nil)
                    return result
                },
                refreshAccessToken: { _ in "unused" }
            )
        )

        let snapshot = await probe.fetch()
        #expect(snapshot.weekly.usedPercentage == nil)
        #expect(snapshot.weekly.message == "No Gemini weekly limit returned.")
        #expect(snapshot.modelWindows.first?.window.usedPercentage == 0)
    }
}
