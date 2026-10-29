import Foundation
import Network
import Testing
@testable import TokenWatch

struct UsageAPIServerTests {
    @MainActor private func offlineStore(
        claudeProbe: any ProviderSnapshotFetching,
        codexProbe: any ProviderSnapshotFetching
    ) -> UsageStore {
        UsageStore(
            claudeProbe: claudeProbe,
            codexProbe: codexProbe,
            geminiProbe: CountingProbe(snapshot: makeSnapshot(.gemini), counter: CallCounter()),
            zaiProbe: CountingProbe(snapshot: makeSnapshot(.zai), counter: CallCounter()),
            museProbe: CountingProbe(snapshot: makeSnapshot(.muse), counter: CallCounter()),
            alicloudProbe: CountingProbe(snapshot: makeSnapshot(.alicloud), counter: CallCounter()),
            commandCodeProbe: CountingProbe(snapshot: makeSnapshot(.commandCode), counter: CallCounter()),
            startRefreshLoop: false
        )
    }

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

    @Test func historyRoutesValidateAndEncodePassedResponse() throws {
        let router = router()
        let response = UsageHistory.response(series: [], range: .week, now: Date(timeIntervalSince1970: 1_790_000_000))
        let result = router.respond(method: "GET", path: "/history", historyResponse: response)
        #expect(result.status == 200)
        #expect(result.body == (try UsageAPIRouter.encoder.encode(response)))
        #expect(router.respond(method: "GET", path: "/history?range=bad").status == 400)
        #expect(router.respond(method: "GET", path: "/history?range=").statusLine == "400 Bad Request")
        #expect(router.respond(method: "GET", path: "/history?provider=unknown").status == 404)
        #expect(router.respond(method: "POST", path: "/history", historyResponse: response).status == 405)
        #expect(router.respond(method: "HEAD", path: "/history", historyResponse: response).status == 405)
        #expect(router.respond(method: "GET", path: "/history?range=all&provider=claude", historyResponse: response).status == 200)
        #expect(UsageAPIRouter.historyQuery("/history").range == .week)
        #expect(String(decoding: router.respond(method: "GET", path: "/missing").body, as: UTF8.self).contains("/history"))
    }

    @Test @MainActor func historyServerReadsStorageWithoutFetching() async throws {
        let claudeCalls = CallCounter(), codexCalls = CallCounter()
        let store = offlineStore(
            claudeProbe: CountingProbe(snapshot: makeSnapshot(.claude), counter: claudeCalls),
            codexProbe: CountingProbe(snapshot: makeSnapshot(.codex), counter: codexCalls))
        try await store.historyStore.record(makeSnapshot(.claude, weeklyUsed: 42))
        try await store.historyStore.record(makeSnapshot(.codex, fiveHourUsed: 10))
        let server = UsageAPIServer(store: store, followSettings: false)
        let peer = NWEndpoint.hostPort(host: "127.0.0.1", port: 12345)
        let response = await server.respond(to: "GET /history?range=all&provider=claude HTTP/1.1\r\nHost: test", peer: peer)
        #expect(response.status == 200)
        let series = try #require(try json(response)["series"] as? [[String: Any]])
        #expect(series.count == 1)
        #expect(series.first?["provider"] as? String == "claude")
        #expect(await claudeCalls.count == 0)
        #expect(await codexCalls.count == 0)
        #expect(await server.respond(to: "GET /history?range=invalid HTTP/1.1", peer: peer).status == 400)
        #expect(await server.respond(to: "GET /history?provider HTTP/1.1", peer: peer).status == 404)
        #expect(await server.respond(to: "GET /history?provider=unknown HTTP/1.1", peer: peer).status == 404)
        #expect(await server.respond(to: "POST /history HTTP/1.1", peer: peer).status == 405)
        #expect(server.state == .stopped)
    }

    @Test func routesHealthBulkAndSingleProvider() throws {
        let router = router()

        let health = router.respond(method: "GET", path: "/health")
        #expect(health.status == 200)
        #expect(try json(health)["status"] as? String == "ok")

        let bulk = router.respond(method: "GET", path: "/usage?x=1")
        #expect(bulk.status == 200)
        let all = try json(bulk)
        #expect(Set(all.keys) == Set(ProviderKind.allCases.map(\.routeKey) + ["last_updated", "banked_reset_auto_apply"]))
        let claude = try #require(all["claude"] as? [String: Any])
        #expect(claude["provider"] as? String == "Claude")
        #expect((claude["five_hour"] as? [String: Any])?["used_percentage"] as? Double == 12.5)
        #expect((claude["weekly"] as? [String: Any])?["kind"] as? String == "Week")
        #expect(((claude["model_windows"] as? [[String: Any]])?.first?["model_name"]) as? String == "Fable")
        #expect(claude["detail"] as? String == "Max")
        #expect(claude["pace_delta"] as? Double != nil)
        #expect((claude["updated_at"] as? String)?.hasPrefix("2026-") == true)
        #expect(router.respond(method: "POST", path: "/refresh").body == bulk.body)

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
        #expect(router.respond(method: "POST", path: "/health").status == 405)
        #expect(router.respond(method: "GET", path: "/refresh").status == 404)
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

    @Test func lanAuthenticationAndLoopbackBypass() {
        let remote = NWEndpoint.hostPort(host: "192.168.1.8", port: 8037)
        let head = "GET /health HTTP/1.1\r\nHost: mac"
        #expect(!UsageAPIRouter.isAuthorized(head: head, peer: remote, lanEnabled: true, token: "secret"))
        #expect(!UsageAPIRouter.isAuthorized(head: head + "\r\nAuthorization: Bearer wrong", peer: remote, lanEnabled: true, token: "secret"))
        #expect(UsageAPIRouter.isAuthorized(head: head + "\r\naUtHoRiZaTiOn: bEaReR secret", peer: remote, lanEnabled: true, token: "secret"))
        #expect(!UsageAPIRouter.isAuthorized(head: head + "\r\nAuthorization: Bearer secret", peer: remote, lanEnabled: false, token: "secret"))
        #expect(!UsageAPIRouter.isAuthorized(head: head + "\r\nAuthorization: Bearer secret", peer: remote, lanEnabled: true, token: nil))
        #expect(!UsageAPIRouter.isAuthorized(head: head + "\r\nAuthorization: Bearer secret\r\nAuthorization: Bearer secret", peer: remote, lanEnabled: true, token: "secret"))
        for host: NWEndpoint.Host in ["127.0.0.1", "127.0.0.2", "::1", "::ffff:127.0.0.1"] {
            #expect(UsageAPIRouter.isAuthorized(head: head, peer: .hostPort(host: host, port: 8037), lanEnabled: true, token: nil))
        }
        #expect(!UsageAPIRouter.isLoopback(.hostPort(host: "::2", port: 8037)))
    }

    @Test func lanSettingsAreOptInAndTokenPersists() {
        let name = "UsageAPILANSettingsTests"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!UsageAPISettings.isLANEnabled(defaults))
        let token = UsageAPISettings.accessToken(defaults)
        #expect(!token.isEmpty)
        #expect(UsageAPISettings.accessToken(defaults) == token)
        #expect(UsageAPISettings.regenerateAccessToken(defaults) != token)
        defaults.set(true, forKey: UsageAPISettings.lanEnabledKey)
        #expect(UsageAPISettings.isLANEnabled(defaults))
    }

    @Test(arguments: [false, true]) @MainActor func listenerServesUsageOverLoopback(lanEnabled: Bool) async throws {
        let probe = SequencedAPIProbe([makeSnapshot(.claude, fiveHourUsed: 5, weeklyUsed: 6),
                                       makeSnapshot(.claude, fiveHourUsed: 11, weeklyUsed: 12)])
        let store = offlineStore(
            claudeProbe: probe,
            codexProbe: CountingProbe(snapshot: makeSnapshot(.codex), counter: CallCounter())
        )
        let server = UsageAPIServer(store: store, userDefaults: UserDefaults(suiteName: "UsageAPIServerListenerTests")!, followSettings: false)
        let port = Int.random(in: 20_000 ... 60_000)
        server.start(port: port, lanEnabled: lanEnabled, accessToken: lanEnabled ? "socket-test-key" : nil)
        defer { server.stop() }

        let ready = await waitUntil { await MainActor.run { server.state == .listening(port: port) } }
        #expect(ready, "server state: \(server.state)")

        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/usage/claude")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(payload["provider"] as? String == "Claude")
        #expect((payload["five_hour"] as? [String: Any])?["used_percentage"] as? Double == nil)
        #expect(await probe.calls == 0)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/refresh")!)
        request.httpMethod = "POST"
        let (refreshedData, refreshedResponse) = try await URLSession.shared.data(for: request)
        #expect((refreshedResponse as? HTTPURLResponse)?.statusCode == 200)
        let refreshed = try #require(try JSONSerialization.jsonObject(with: refreshedData) as? [String: Any])
        let refreshedClaude = try #require(refreshed["claude"] as? [String: Any])
        #expect((refreshedClaude["five_hour"] as? [String: Any])?["used_percentage"] as? Double == 5)
        #expect(refreshedClaude["updated_at"] as? String != nil)
        #expect(refreshed["last_updated"] as? String != nil)
        #expect(await probe.calls == 1)

        let (afterData, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/usage")!)
        #expect(afterData == refreshedData)
        #expect(await probe.calls == 1)

        let (_, health) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)
        #expect((health as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test @MainActor func simultaneousRefreshesAndExistingCollectionShareOneProbe() async throws {
        let paused = PausedAPIProbe(snapshot: makeSnapshot(.claude, fiveHourUsed: 77))
        let store = offlineStore(claudeProbe: paused,
                                 codexProbe: CountingProbe(snapshot: makeSnapshot(.codex), counter: CallCounter()))
        let server = UsageAPIServer(store: store, followSettings: false)
        let peer = NWEndpoint.hostPort(host: "127.0.0.1", port: 9000)
        let head = "POST /refresh HTTP/1.1\r\nHost: mac"

        let existing = Task { await store.refresh(.claude) }
        #expect(await waitUntil { await paused.calls == 1 })
        let first = Task { await server.respond(to: head, peer: peer) }
        let second = Task { await server.respond(to: head, peer: peer) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await paused.calls == 1)
        await paused.release()
        await existing.value
        let firstResponse = await first.value
        let secondResponse = await second.value
        #expect(firstResponse.status == 200)
        #expect(firstResponse.body == secondResponse.body)
        let body = try json(firstResponse)
        let claude = try #require(body["claude"] as? [String: Any])
        #expect((claude["five_hour"] as? [String: Any])?["used_percentage"] as? Double == 77)
        #expect(await paused.calls == 1)
    }

    @Test @MainActor func unauthorizedRemoteRefreshDoesNotStartProbes() async {
        let counter = CallCounter()
        let store = offlineStore(
            claudeProbe: CountingProbe(snapshot: makeSnapshot(.claude), counter: counter),
            codexProbe: CountingProbe(snapshot: makeSnapshot(.codex), counter: CallCounter())
        )
        let server = UsageAPIServer(store: store, followSettings: false)
        server.start(port: Int.random(in: 20_000 ... 60_000), lanEnabled: true, accessToken: "secret")
        defer { server.stop() }
        let remote = NWEndpoint.hostPort(host: "192.168.1.8", port: 9000)
        let missing = await server.respond(to: "POST /refresh HTTP/1.1\r\nHost: mac", peer: remote)
        let wrong = await server.respond(to: "POST /refresh HTTP/1.1\r\nAuthorization: Bearer wrong", peer: remote)
        #expect(missing.status == 401)
        #expect(wrong.status == 401)
        #expect(await counter.count == 0)
    }
}

private actor SequencedAPIProbe: ProviderSnapshotFetching {
    private var snapshots: [ProviderSnapshot]
    private(set) var calls = 0
    init(_ snapshots: [ProviderSnapshot]) { self.snapshots = snapshots }
    func fetch() -> ProviderSnapshot {
        calls += 1
        return snapshots.count > 1 ? snapshots.removeFirst() : snapshots[0]
    }
}

private actor PausedAPIProbe: ProviderSnapshotFetching {
    private let snapshot: ProviderSnapshot
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    init(snapshot: ProviderSnapshot) { self.snapshot = snapshot }
    func fetch() async -> ProviderSnapshot {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
        return snapshot
    }
    func release() { continuation?.resume(); continuation = nil }
}
