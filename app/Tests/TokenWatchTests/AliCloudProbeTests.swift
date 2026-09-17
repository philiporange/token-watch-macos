import Foundation
import Testing
@testable import TokenWatch

struct AliCloudProbeTests {
    @Test
    func credentialLoaderPrefersEnvironmentThenDotEnvThenMuonSessions() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent("Library/Application Support/Muon/website-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let plist: [String: Any] = ["cookies": [
            ["Domain": ".example.com", "Name": "login_aliyunid_ticket", "Value": "wrong-domain"],
            ["Domain": ".alibabacloud.com", "Name": "login_aliyunid", "Value": "user"],
            ["Domain": ".alibabacloud.com", "Name": "login_aliyunid_ticket", "Value": "muon-ticket", "HttpOnly": "TRUE"],
        ]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: sessions.appendingPathComponent("default.plist"))

        #expect(AliCloudCredentialLoader(homeDirectory: home, environment: [:]).loadTicket() == "muon-ticket")

        try "ALICLOUD_CONSOLE_TICKET=\"file-ticket\"\n".write(to: home.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        #expect(AliCloudCredentialLoader(homeDirectory: home, environment: [:]).loadTicket() == "file-ticket")
        #expect(AliCloudCredentialLoader(homeDirectory: home, environment: ["ALICLOUD_CONSOLE_TICKET": " env-ticket "]).loadTicket() == "env-ticket")
    }

    @Test
    func gatewayRequestCarriesTicketCookieAndConsoleEnvelope() throws {
        let request = AliCloudProbe.gatewayRequest(api: AliCloudProbe.usageAPI, data: [:], ticket: " ticket ")

        #expect(request.httpMethod == "POST")
        #expect(request.url?.host == "bailian-singapore-cs.alibabacloud.com")
        #expect(request.url?.query?.contains("action=IntlBroadScopeAspnGateway") == true)
        #expect(request.url?.query?.contains("api=zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage") == true)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "login_aliyunid_ticket=ticket")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")

        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        var components = URLComponents()
        components.percentEncodedQuery = body
        let fields = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(fields["region"] == "ap-southeast-1")
        let params = try #require(try JSONSerialization.jsonObject(with: Data(fields["params"]!.utf8)) as? [String: Any])
        #expect(params["Api"] as? String == AliCloudProbe.usageAPI)
        #expect(params["V"] as? String == "1.0")
        let data = try #require(params["Data"] as? [String: Any])
        #expect((data["cornerstoneParam"] as? [String: Int])?["switchUserType"] == 3)
    }

    @Test
    func envelopeUnwrapsPayloadAndTranslatesLoginErrors() throws {
        let success = Data("""
        {"code":"200","data":{"DataV2":{"ret":["SUCCESS::ok"],"data":{"code":"SUCCESS","data":{"per1WeekResetTime":1790211240000,"per1WeekPercentage":0.00025}}},"success":true,"errorCode":""}}
        """.utf8)
        let payload = try AliCloudProbe.unwrapGatewayEnvelope(success)
        #expect((payload["per1WeekPercentage"] as? Double) == 0.00025)

        let expired = Data("""
        {"code":"200","data":{"success":false,"httpStatus":200,"errorCode":"BailianGateway.Login.NotLogined","errorMsg":"BailianGateway.Login.NotLogined"}}
        """.utf8)
        #expect(throws: AliCloudError.sessionExpired) {
            try AliCloudProbe.unwrapGatewayEnvelope(expired)
        }
    }

    @Test
    func fetchMapsWeeklyFractionAndSubscriptionDetail() async {
        let probe = AliCloudProbe(
            credentialLoader: AliCloudCredentialLoader(homeDirectory: URL(fileURLWithPath: "/nonexistent"), environment: ["ALICLOUD_CONSOLE_TICKET": "t"]),
            apiClient: AliCloudAPIClient(
                fetchUsage: { _ in AliCloudUsage(weeklyFraction: 0.4275, weeklyResetTime: 1_790_211_240_000) },
                fetchSubscription: { _ in AliCloudSubscription(specCode: "lite", remainingDays: 4) }
            )
        )

        let snapshot = await probe.fetch()

        #expect(snapshot.provider == .alicloud)
        #expect(snapshot.fiveHour.usedPercentage == nil)
        #expect(snapshot.weekly.kind == .weekly)
        #expect(snapshot.weekly.usedPercentage == 42.75)
        #expect(snapshot.weekly.resetsAt == Date(timeIntervalSince1970: 1_790_211_240))
        #expect(snapshot.detail == "Lite plan · 4 days left")
        #expect(StatusItemFormatter.content(name: "Ali", snapshot: snapshot).metrics.map(\.label) == ["7d", "p"])
    }

    @Test
    func fetchSurvivesSubscriptionFailureAndReportsExpiredSession() async {
        let loader = AliCloudCredentialLoader(homeDirectory: URL(fileURLWithPath: "/nonexistent"), environment: ["ALICLOUD_CONSOLE_TICKET": "t"])
        let partial = AliCloudProbe(
            credentialLoader: loader,
            apiClient: AliCloudAPIClient(
                fetchUsage: { _ in AliCloudUsage(weeklyFraction: 0.1, weeklyResetTime: nil) },
                fetchSubscription: { _ in throw AliCloudError.invalidResponse("boom") }
            )
        )
        let partialSnapshot = await partial.fetch()
        #expect(partialSnapshot.weekly.usedPercentage == 10)
        #expect(partialSnapshot.detail == nil)

        let expired = AliCloudProbe(
            credentialLoader: loader,
            apiClient: AliCloudAPIClient(
                fetchUsage: { _ in throw AliCloudError.sessionExpired },
                fetchSubscription: { _ in AliCloudSubscription(specCode: nil, remainingDays: nil) }
            )
        )
        let expiredSnapshot = await expired.fetch()
        #expect(expiredSnapshot.weekly.message == AliCloudError.sessionExpired.localizedDescription)

        let missing = await AliCloudProbe(credentialLoader: AliCloudCredentialLoader(homeDirectory: URL(fileURLWithPath: "/nonexistent"), environment: [:])).fetch()
        #expect(missing.fiveHour.message?.contains("credentials not found") == true)
    }
}
