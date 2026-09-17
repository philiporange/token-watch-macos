import Foundation
import Testing
@testable import TokenWatch

struct CommandCodeProbeTests {
    @Test
    func credentialLoaderPrefersEnvironmentOverAuthFile() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent(".commandcode", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"apiKey": " user_file ", "userName": "x"}"#.write(to: dir.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)

        #expect(CommandCodeCredentialLoader(homeDirectory: home, environment: [:]).loadAPIKey() == "user_file")
        #expect(CommandCodeCredentialLoader(homeDirectory: home, environment: ["COMMANDCODE_API_KEY": "user_env"]).loadAPIKey() == "user_env")
        #expect(CommandCodeCredentialLoader(homeDirectory: URL(fileURLWithPath: "/nonexistent"), environment: [:]).loadAPIKey() == nil)
    }

    @Test
    func requestUsesBearerKeyAgainstAlphaAPI() {
        let request = CommandCodeProbe.request(path: "/alpha/billing/credits", apiKey: " key ")
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.commandcode.ai/alpha/billing/credits")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer key")
    }

    @Test
    func creditsResponseDecodesLiveShape() throws {
        let data = Data("""
        {"credits":{"belowThreshold":false,"creditThreshold":0,"monthlyCredits":9.456792772,"purchasedCredits":0,"freeCredits":0},
         "windowLimits":{"limited":true,"exceeded":null,
           "fiveHour":{"used":0.533506296,"cap":3,"exceeded":false,"resetAt":1789624802266},
           "weekly":{"used":"0.533506296","cap":6,"exceeded":false,"resetAt":1790211602266}}}
        """.utf8)
        let credits = try JSONDecoder().decode(CommandCodeCredits.self, from: data)
        #expect(credits.monthlyCredits == 9.456792772)
        #expect(credits.fiveHour?.cap == 3)
        #expect(credits.weekly?.used == 0.533506296)
        #expect(credits.weekly?.resetAt == 1_790_211_602_266)

        let subscription = try JSONDecoder().decode(CommandCodeSubscriptionResponse.self, from: Data("""
        {"success":true,"data":{"id":"sub_1","status":"active","currentPeriodEnd":"2026-09-20T22:26:41.000Z","planId":"individual-go"}}
        """.utf8)).data
        #expect(subscription.planId == "individual-go")
        #expect(subscription.currentPeriodEnd == Date(timeIntervalSince1970: 1_789_943_201))
    }

    @Test
    func planTableMatchesLongestPrefix() {
        #expect(CommandCodePlan(planId: "individual-go")?.name == "Go")
        #expect(CommandCodePlan(planId: "individual-go")?.monthlyCredits == 10)
        #expect(CommandCodePlan(planId: "individual-goat-monthly")?.name == "GOAT")
        #expect(CommandCodePlan(planId: "individual_pro_v1")?.monthlyCredits == 80)
        #expect(CommandCodePlan(planId: "individual-pro")?.monthlyCredits == 30)
        #expect(CommandCodePlan(planId: "enterprise") == nil)
    }

    @Test
    func fetchMapsWindowsCreditsAndDetail() async {
        let probe = CommandCodeProbe(
            credentialLoader: CommandCodeCredentialLoader(homeDirectory: URL(fileURLWithPath: "/nonexistent"), environment: ["COMMANDCODE_API_KEY": "k"]),
            apiClient: CommandCodeAPIClient(
                fetchCredits: { _ in CommandCodeCredits(
                    monthlyCredits: 7.5,
                    fiveHour: CommandCodeWindowLimit(used: 0.75, cap: 3, resetAt: 1_789_624_802_266),
                    weekly: CommandCodeWindowLimit(used: 1.5, cap: 6, resetAt: 1_790_211_602_266)
                ) },
                fetchSubscription: { _ in CommandCodeSubscription(planId: "individual-go", currentPeriodEnd: Date(timeIntervalSince1970: 1_789_943_201)) }
            )
        )

        let snapshot = await probe.fetch()

        #expect(snapshot.provider == .commandCode)
        #expect(snapshot.fiveHour.usedPercentage == 25)
        #expect(snapshot.fiveHour.resetsAt == Date(timeIntervalSince1970: 1_789_624_802.266))
        #expect(snapshot.weekly.usedPercentage == 25)
        #expect(snapshot.modelWindows.count == 1)
        #expect(snapshot.modelWindows[0].modelName == "Credits")
        #expect(snapshot.modelWindows[0].window.kind == .monthly)
        #expect(snapshot.modelWindows[0].window.usedPercentage == 25)
        #expect(snapshot.modelWindows[0].window.resetsAt == Date(timeIntervalSince1970: 1_789_943_201))
        #expect(snapshot.detail == "Go plan · $7.50 credits left")
    }

    @Test
    func fetchReportsMissingCredentialsAndAuthFailures() async {
        let missing = await CommandCodeProbe(credentialLoader: CommandCodeCredentialLoader(homeDirectory: URL(fileURLWithPath: "/nonexistent"), environment: [:])).fetch()
        #expect(missing.weekly.message?.contains("credentials not found") == true)

        let failing = CommandCodeProbe(
            credentialLoader: CommandCodeCredentialLoader(homeDirectory: URL(fileURLWithPath: "/nonexistent"), environment: ["COMMANDCODE_API_KEY": "k"]),
            apiClient: CommandCodeAPIClient(
                fetchCredits: { _ in throw CommandCodeError.authenticationFailed },
                fetchSubscription: { _ in CommandCodeSubscription(planId: nil, currentPeriodEnd: nil) }
            )
        )
        let snapshot = await failing.fetch()
        #expect(snapshot.fiveHour.message == CommandCodeError.authenticationFailed.localizedDescription)
        #expect(snapshot.modelWindows.isEmpty)
    }
}
