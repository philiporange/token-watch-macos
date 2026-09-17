import Foundation
import Testing
@testable import TokenWatch

struct UsageAPIServerTests {
    private func router(now: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> UsageAPIRouter {
        UsageAPIRouter(
            providers: { provider in
                let snapshot: ProviderSnapshot
                if provider == .claude {
                    snapshot = makeSnapshot(.claude, fiveHourUsed: 12.5, weeklyUsed: 40, weeklyReset: now.addingTimeInterval(3 * 24 * 3600), modelWindows: [
                        ModelUsageWindow(modelName: "Fable", window: makeWindow(.modelWeekly, used: 55, resetsAt: now.addingTimeInterval(86_400)), isActive: true),
                    ], detail: "Max")
                } else {
                    snapshot = makeSnapshot(provider, fiveHourMessage: "Loading…", weeklyMessage: "Loading…")
                }
                return UsageAPIProviderPayload(snapshot: snapshot, updatedAt: provider == .claude ? now : nil, now: now)
            },
            lastUpdated: { now }
        )
    }

    private func json(_ response: UsageAPIResponse) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    @Test func routesHealthBulkAndSingleProvider() throws {
        let router = router()

        let health = router.respond(method: "GET", path: "/health")
        #expect(health.status == 200)
        #expect(try json(health)["status"] as? String == "ok")

        let bulk = router.respond(method: "GET", path: "/usage?x=1")
        #expect(bulk.status == 200)
        let all = try json(bulk)
        #expect(Set(all.keys) == Set(ProviderKind.allCases.map(\.routeKey) + ["last_updated"]))
        let claude = try #require(all["claude"] as? [String: Any])
        #expect(claude["provider"] as? String == "Claude")
        #expect((claude["five_hour"] as? [String: Any])?["used_percentage"] as? Double == 12.5)
        #expect((claude["weekly"] as? [String: Any])?["kind"] as? String == "Week")
        #expect(((claude["model_windows"] as? [[String: Any]])?.first?["model_name"]) as? String == "Fable")
        #expect(claude["detail"] as? String == "Max")
        #expect(claude["pace_delta"] as? Double != nil)
        #expect((claude["updated_at"] as? String)?.hasPrefix("2026-") == true)

        let single = router.respond(method: "GET", path: "/usage/CommandCode")
        #expect(single.status == 200)
        #expect(try json(single)["provider"] as? String == "Command Code")
        #expect((try json(single)["weekly"] as? [String: Any])?["message"] as? String == "Loading…")
    }

    @Test func rejectsUnknownRoutesAndMethods() throws {
        let router = router()
        #expect(router.respond(method: "GET", path: "/usage/nope").status == 404)
        #expect(router.respond(method: "GET", path: "/").status == 404)
        #expect(router.respond(method: "POST", path: "/usage").status == 405)
        #expect(UsageAPIRouter.parseRequestLine("GET /usage HTTP/1.1\r\nHost: x")! == ("GET", "/usage"))
        #expect(UsageAPIRouter.parseRequestLine("garbage") == nil)

        let serialized = String(decoding: router.respond(method: "GET", path: "/health").serialized(), as: UTF8.self)
        #expect(serialized.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(serialized.contains("Content-Type: application/json\r\n"))
        #expect(serialized.hasSuffix("{\"status\":\"ok\"}"))
    }

    @Test func routeKeysRoundTrip() {
        #expect(ProviderKind.commandCode.routeKey == "commandcode")
        #expect(ProviderKind.zai.routeKey == "zai")
        for provider in ProviderKind.allCases {
            #expect(ProviderKind.from(routeKey: provider.routeKey) == provider)
        }
    }

    @Test func settingsFallBackToDefaultsForInvalidValues() {
        let defaults = UserDefaults(suiteName: "UsageAPISettingsTests")!
        defaults.removePersistentDomain(forName: "UsageAPISettingsTests")
        #expect(UsageAPISettings.isEnabled(defaults) == false)
        #expect(UsageAPISettings.port(defaults) == UsageAPISettings.defaultPort)
        defaults.set(70_000, forKey: UsageAPISettings.portKey)
        #expect(UsageAPISettings.port(defaults) == UsageAPISettings.defaultPort)
        defaults.set(9_123, forKey: UsageAPISettings.portKey)
        #expect(UsageAPISettings.port(defaults) == 9_123)
    }

    @Test @MainActor func listenerServesUsageOverLoopback() async throws {
        let store = UsageStore(
            claudeProbe: CountingProbe(snapshot: makeSnapshot(.claude, fiveHourUsed: 5, weeklyUsed: 6), counter: CallCounter()),
            codexProbe: CountingProbe(snapshot: makeSnapshot(.codex), counter: CallCounter()),
            startRefreshLoop: false
        )
        await store.refresh(.claude)
        let server = UsageAPIServer(store: store, userDefaults: UserDefaults(suiteName: "UsageAPIServerListenerTests")!, followSettings: false)
        let port = Int.random(in: 20_000 ... 60_000)
        server.start(port: port)
        defer { server.stop() }

        let ready = await waitUntil { await MainActor.run { server.state == .listening(port: port) } }
        #expect(ready, "server state: \(server.state)")

        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/usage/claude")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(payload["provider"] as? String == "Claude")
        #expect((payload["five_hour"] as? [String: Any])?["used_percentage"] as? Double == 5)

        let (_, health) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)
        #expect((health as? HTTPURLResponse)?.statusCode == 200)
    }
}
