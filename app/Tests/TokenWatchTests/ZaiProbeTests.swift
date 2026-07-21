import Foundation
import Testing
@testable import TokenWatch

struct ZaiProbeTests {
    @Test
    func credentialLoaderReadsOnlyZaiAPIKeyFromDotEnv() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dotenv = home.appendingPathComponent(".env")
        try """
        ANTHROPIC_AUTH_TOKEN=must-not-be-used
        export ZAI_API_KEY="zai-secret"
        """.write(to: dotenv, atomically: true, encoding: .utf8)

        let loader = ZaiCredentialLoader(homeDirectory: home, environment: [:])

        #expect(loader.loadToken() == "zai-secret")

        try "ANTHROPIC_AUTH_TOKEN=must-not-be-used\n".write(to: dotenv, atomically: true, encoding: .utf8)
        #expect(loader.loadToken() == nil)
    }

    @Test
    func credentialLoaderPrefersInheritedZaiAPIKey() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try "ZAI_API_KEY=file-key\n".write(
            to: home.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )

        let loader = ZaiCredentialLoader(
            homeDirectory: home,
            environment: ["ZAI_API_KEY": " process-key ", "ANTHROPIC_AUTH_TOKEN": "ignored"]
        )

        #expect(loader.loadToken() == "process-key")
    }

    @Test
    func quotaRequestUsesDirectAuthorizationHeaderAndNoQuery() {
        let request = ZaiProbe.quotaRequest(with: "  zai-key  ")

        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.z.ai/api/monitor/usage/quota/limit")
        #expect(request.url?.query == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "zai-key")
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en-US,en")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test
    func fetchMapsTokenAndToolLimitsToFiveHourAndMonthlyWindows() async throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try "ZAI_API_KEY=test-key\n".write(
            to: home.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )
        let resetMilliseconds = 1_800_000_000_000.0
        let probe = ZaiProbe(
            credentialLoader: ZaiCredentialLoader(homeDirectory: home, environment: [:]),
            apiClient: ZaiAPIClient { _ in
                ZaiQuotaResponse(data: ZaiQuotaData(
                    limits: [
                        ZaiQuotaLimit(type: "TOKENS_LIMIT", percentage: 23, nextResetTime: resetMilliseconds),
                        ZaiQuotaLimit(type: "TIME_LIMIT", percentage: 41),
                    ],
                    planName: "Pro"
                ))
            }
        )

        let snapshot = await probe.fetch()

        #expect(snapshot.provider == .zai)
        #expect(snapshot.fiveHour.kind == .fiveHour)
        #expect(snapshot.fiveHour.usedPercentage == 23)
        #expect(snapshot.fiveHour.resetsAt == Date(timeIntervalSince1970: resetMilliseconds / 1_000))
        #expect(snapshot.weekly.kind == .monthly)
        #expect(snapshot.weekly.usedPercentage == 41)
        #expect(snapshot.weekly.resetsAt == nil)
        #expect(snapshot.detail == "Pro")
    }

    @Test
    func quotaResponseToleratesStringNumbersAndPlanAliases() throws {
        let data = Data("""
        {
          "data": {
            "plan_type": "Lite",
            "limits": [
              {"type": "TOKENS_LIMIT", "percentage": "12.5", "nextResetTime": "1800000000000"},
              {"type": "TIME_LIMIT", "percentage": 7}
            ]
          }
        }
        """.utf8)

        let response = try JSONDecoder().decode(ZaiQuotaResponse.self, from: data)

        #expect(response.data?.planName == "Lite")
        #expect(response.data?.limits[0].percentage == 12.5)
        #expect(response.data?.limits[0].nextResetTime == 1_800_000_000_000)
        #expect(response.data?.limits[1].percentage == 7)
    }
}
