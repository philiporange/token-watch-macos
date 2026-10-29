import Foundation
import Network
import Testing
@testable import TokenWatch

@Suite struct BankedResetParsingTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func codexCreditsAreNormalizedAndInvalidIDsSkipped() throws {
        let credits: [String: Any] = ["credits": [
            ["id": "ok_1", "status": "available", "expiresAt": now.timeIntervalSince1970 + 60],
            ["id": "expired", "status": "available", "expiresAt": now.timeIntervalSince1970],
            ["id": "used", "status": "redeemed"], ["id": "busy", "status": "redeeming"],
            ["id": "unknown", "status": "future"], ["id": "bad/id", "status": "available"]
        ]]
        let parsed = CodexProbe.parseBankedResets(credits, now: now)
        #expect(parsed.count == 5)
        #expect(parsed[0].usable && parsed[0].remaining == 1)
        #expect(parsed[0].title == "Codex reset")
        #expect(parsed.map(\.status) == ["available", "expired", "redeemed", "redeeming", "unknown"])
        #expect(parsed.dropFirst().allSatisfy { !$0.usable && $0.remaining == 0 })
        #expect(CodexProbe.parseBankedResets(["credits": NSNull()]).isEmpty)
        #expect(CodexProbe.parseBankedResets(NSNull()).isEmpty)
    }

    private func claude(block: [String: Any]) throws -> [BankedReset] {
        let data = try JSONSerialization.data(withJSONObject: ["cedar_ember": block])
        return try JSONDecoder().decode(ClaudeUsageResponse.self, from: data).cedarEmber?.bankedResets(now: now) ?? []
    }

    @Test func claudeGrantEligibilityNotesAndLenientDecoding() throws {
        let grant: [String: Any] = ["id": "g1", "label": "Full reset", "resets_left": 1,
            "starts_at": now.addingTimeInterval(-100).ISO8601Format(),
            "ends_at": now.addingTimeInterval(200).ISO8601Format(),
            "paused": false, "usable_now": true, "use_requires_limit": true, "clears": ["five_hour", "seven_day"]]
        var block: [String: Any] = ["eligible": true, "next_grant_id": "g1", "grants": [grant, ["id": "malformed"]]]
        let usable = try #require(claude(block: block).first)
        #expect(usable.usable && usable.status == "available")
        #expect(usable.detail == "Refills 5h and weekly limits")
        block["eligible"] = false
        block["ineligible_reason"] = "surface"
        #expect(try claude(block: block).first?.note == "Claude only allows this reset on claude.ai or Claude Desktop.")
        block["eligible"] = true
        block["cooldown_until"] = now.addingTimeInterval(100).ISO8601Format()
        #expect(try claude(block: block).first?.note?.contains("after") == true)
        block.removeValue(forKey: "cooldown_until")
        var changed = grant
        changed["usable_now"] = false
        block["grants"] = [changed]
        #expect(try claude(block: block).first?.note?.contains("reach a limit") == true)
        changed["resets_left"] = 0
        block["grants"] = [changed]
        #expect(try claude(block: block).first?.status == "redeemed")
        #expect(try claude(block: block).first?.note == nil)
        changed["resets_left"] = 1
        changed["ends_at"] = now.ISO8601Format()
        block["grants"] = [changed]
        #expect(try claude(block: block).first?.status == "expired")
        changed["ends_at"] = now.addingTimeInterval(100).ISO8601Format()
        changed["paused"] = true
        block["grants"] = [changed]
        #expect(try claude(block: block).first?.status == "paused")
        changed["id"] = "bad/id"
        block["grants"] = [changed]
        #expect(try claude(block: block).isEmpty)
        for json in [#"{"cedar_ember":null}"#, #"{"cedar_ember":"bad"}"#, #"{"cedar_ember":{"eligible":"wrong","grants":[]}}"#, "{}"] {
            let usage = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))
            #expect(usage.cedarEmber?.bankedResets(now: now).isEmpty ?? true)
        }
    }

    @Test func identifiersAndExpiryLabels() {
        #expect(BankedReset.validID("credit_123-ok"))
        #expect(!BankedReset.validID("credit\n"))
        #expect(!BankedReset.validID(String(repeating: "a", count: 129)))
        let loc = Loc()
        #expect(loc.bankedResetExpiry(.init(id: "id", title: "Full", expiresAt: now.addingTimeInterval(16500)), now: now) == "Expires in 4h 35m")
        #expect(loc.bankedResetExpiry(.init(id: "id", title: "Full", expiresAt: now), now: now) == "Expired")
        for language in AppLanguage.allCases {
            #expect(!Loc(lang: language).bankedResetAutoDescription.isEmpty)
            #expect(!Loc(lang: language).bankedResetConfirmation.isEmpty)
        }
    }

    @Test func duePolicyBoundariesAndThrottling() {
        var reset = BankedReset(id: "id", title: "Reset", expiresAt: now.addingTimeInterval(300), usable: true)
        #expect(BankedResetAutoApplyPolicy.isDue(reset, now: now, leadMinutes: 5))
        #expect(!BankedResetAutoApplyPolicy.isDue(reset, now: now, leadMinutes: 4))
        #expect(!BankedResetAutoApplyPolicy.isDue(reset, now: now, leadMinutes: 5, completed: true))
        #expect(!BankedResetAutoApplyPolicy.isDue(reset, now: now, leadMinutes: 5, lastAttempt: now.addingTimeInterval(-59)))
        #expect(BankedResetAutoApplyPolicy.isDue(reset, now: now, leadMinutes: 5, lastAttempt: now.addingTimeInterval(-60)))
        reset.expiresAt = now
        #expect(!BankedResetAutoApplyPolicy.isDue(reset, now: now, leadMinutes: 5))
        reset.expiresAt = nil
        #expect(!BankedResetAutoApplyPolicy.isDue(reset, now: now, leadMinutes: 60))
    }
}

private struct FakeCodexResetTransport: CodexResetTransport {
    let response: String
    var failure: CodexConsumeFailure? = nil
    func consume(id: String, idempotencyKey: String) async throws -> Data {
        if let failure { throw failure }
        return Data(response.utf8)
    }
}

private actor FakeClaudeResetTransport: ClaudeResetTransport {
    struct Reply: Sendable {
        var status: Int = 200
        var body: String = "{}"
        var fails = false
    }
    var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: URLRequest) throws -> (Data, Int) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        let reply = replies.removeFirst()
        if reply.fails { throw URLError(.timedOut) }
        return (Data(reply.body.utf8), reply.status)
    }
}

@Suite struct BankedResetApplierTests {
    @Test(arguments: ["reset", "nothingToReset", "noCredit", "alreadyRedeemed", "unknown"])
    func codexOutcomes(outcome: String) async {
        let applier = CodexBankedResetApplier(transport: FakeCodexResetTransport(response: "{\"result\":{\"outcome\":\"\(outcome)\"}}"))
        let result = await applier.apply(id: "id", idempotencyKey: "key")
        let expected: [String: BankedResetOutcome] = ["reset": .reset, "nothingToReset": .nothingToReset, "noCredit": .noCredit, "alreadyRedeemed": .alreadyRedeemed]
        #expect(result.outcome == expected[outcome, default: .error])
    }

    @Test(arguments: [false, true]) func codexInterruptionPhase(requestWritten: Bool) async {
        let fake = FakeCodexResetTransport(response: "", failure: .init(requestWritten: requestWritten, detail: "EOF or timeout"))
        let result = await CodexBankedResetApplier(transport: fake).apply(id: "id", idempotencyKey: "key")
        #expect(result.outcome == (requestWritten ? .unconfirmed : .error))
    }

    @Test func codexRPCError() async {
        let applier = CodexBankedResetApplier(transport: FakeCodexResetTransport(response: #"{"error":{"message":"denied"}}"#))
        #expect(await applier.apply(id: "id", idempotencyKey: "key").outcome == .error)
    }

    private func probe(refreshes: CallCounter = CallCounter()) -> ClaudeProbe {
        let credentials = ClaudeCredentialResult(oauth: .init(accessToken: "old", refreshToken: "refresh", expiresAt: Date.now.addingTimeInterval(10000).timeIntervalSince1970 * 1000), source: .keychain, fullData: [:])
        return ClaudeProbe(credentialLoader: ClaudeCredentialLoader(homeDirectory: URL(fileURLWithPath: "/nonexistent/banked-reset-test"), environment: [:], keychainLoadOverride: .success(credentials)), apiClient: ClaudeAPIClient(
            fetchStatus: { throw URLError(.unsupportedURL) },
            refreshToken: { credentials, _ in
                await refreshes.increment()
                var updated = credentials
                updated.oauth.accessToken = "new"
                return updated
            },
            fetchUsage: { _ in throw URLError(.unsupportedURL) }
        ))
    }

    @Test(arguments: ["reset", "already_used", "not_limited", "cooldown", "ineligible", "unavailable", "new_result"])
    func claudeOutcomesAndRequestShape(outcome: String) async throws {
        let fake = FakeClaudeResetTransport([.init(body: #"{"organization":{"uuid":"org_1"}}"#), .init(body: "{\"result\":\"\(outcome)\",\"reason\":\"reason\"}")])
        let result = await ClaudeBankedResetApplier(probe: probe(), transport: fake).apply(id: "grant", idempotencyKey: "key")
        let expected: [String: BankedResetOutcome] = ["reset": .reset, "already_used": .alreadyRedeemed, "not_limited": .nothingToReset, "cooldown": .cooldown, "ineligible": .ineligible]
        #expect(result.outcome == expected[outcome, default: .unavailable])
        let requests = await fake.requests
        #expect(requests.map(\.httpMethod) == ["GET", "POST"])
        #expect(requests.last?.url?.path == "/api/organizations/org_1/reset_rate_limits")
        #expect(requests.last?.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        let body = try #require(requests.last?.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(json == ["program": "cedar_ember", "grant_id": "grant", "request_id": "key"])
    }

    @Test(arguments: [401, 403, 429, 500]) func claudeHTTPFailures(status: Int) async {
        let counter = CallCounter()
        let profile = FakeClaudeResetTransport.Reply(body: #"{"organization":{"uuid":"org"}}"#)
        let fake = FakeClaudeResetTransport([profile, .init(status: status), profile, .init(status: status)])
        let result = await ClaudeBankedResetApplier(probe: probe(refreshes: counter), transport: fake).apply(id: "grant", idempotencyKey: "key")
        #expect(result.outcome == (status == 429 ? .rateLimited : .error))
        let auth = status == 401 || status == 403
        #expect(await counter.count == (auth ? 1 : 0))
        let requests = await fake.requests
        #expect(requests.count == (auth ? 4 : 2))
        if auth {
            let first = try? JSONSerialization.jsonObject(with: requests[1].httpBody ?? Data()) as? [String: String]
            let retry = try? JSONSerialization.jsonObject(with: requests[3].httpBody ?? Data()) as? [String: String]
            #expect(first == retry)
            #expect(first?["request_id"] == "key")
            #expect(requests[3].value(forHTTPHeaderField: "Authorization") == "Bearer new")
            #expect(result.detail == "Claude authentication failed.")
        }
    }

    @Test(arguments: [false, true]) func claudeTransportFailureIsNeverRetried(afterPost: Bool) async {
        let fake = FakeClaudeResetTransport(afterPost ? [.init(body: #"{"organization":{"uuid":"org"}}"#), .init(fails: true)] : [.init(fails: true)])
        let result = await ClaudeBankedResetApplier(probe: probe(), transport: fake).apply(id: "grant", idempotencyKey: "key")
        #expect(result.outcome == (afterPost ? .unconfirmed : .error))
        #expect(await fake.requests.count == (afterPost ? 2 : 1))
    }

    @Test func invalidOrganizationNeverPosts() async {
        let fake = FakeClaudeResetTransport([.init(body: #"{"organization":{"uuid":"../bad"}}"#)])
        #expect(await ClaudeBankedResetApplier(probe: probe(), transport: fake).apply(id: "grant", idempotencyKey: "key").outcome == .error)
        #expect(await fake.requests.count == 1)
    }
}

private actor ResetApplierSpy: BankedResetApplying {
    let outcome: BankedResetOutcome
    private(set) var calls: [(String, String)] = []
    init(_ outcome: BankedResetOutcome) { self.outcome = outcome }
    func apply(id: String, idempotencyKey: String) async -> BankedResetUpstreamResult {
        calls.append((id, idempotencyKey))
        try? await Task.sleep(for: .milliseconds(40))
        return .init(outcome: outcome)
    }
}

@Suite @MainActor struct BankedResetStoreAndAPITests {
    private func store(snapshot: ProviderSnapshot, applier: ResetApplierSpy,
                       defaults: UserDefaults, counter: CallCounter = CallCounter()) -> UsageStore {
        UsageStore(claudeProbe: CountingProbe(snapshot: snapshot, counter: counter),
                   codexProbe: CountingProbe(snapshot: makeSnapshot(.codex), counter: CallCounter()),
                   userDefaults: defaults, startRefreshLoop: false, resetAppliers: [.claude: applier])
    }

    private func snapshot(resets: [BankedReset]) -> ProviderSnapshot {
        var snapshot = makeSnapshot(.claude, fiveHourUsed: 90)
        snapshot.bankedResets = resets
        return snapshot
    }

    @Test func validationCoalescingKeysAndRefresh() async throws {
        let suite = "banked-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let applier = ResetApplierSpy(.nothingToReset)
        let counter = CallCounter()
        let initial = snapshot(resets: [.init(id: "yes", title: "Full", usable: true), .init(id: "no", title: "No", note: "Surface only.")])
        let store = store(snapshot: initial, applier: applier, defaults: defaults, counter: counter)
        store.claude = initial
        #expect(await store.applyBankedReset(provider: .claude, id: "missing").outcome == .notFound)
        let blocked = await store.applyBankedReset(provider: .claude, id: "no")
        #expect(blocked.outcome == .notUsable && blocked.message.contains("Surface only."))
        #expect(await applier.calls.isEmpty)
        #expect(await counter.count == 0)
        let first = Task { await store.applyBankedReset(provider: .claude, id: "yes") }
        #expect(await waitUntil { await applier.calls.count == 1 })
        let second = Task { await store.applyBankedReset(provider: .claude, id: "yes") }
        let results = await (first.value, second.value)
        #expect(results.0.message == results.1.message)
        #expect(await applier.calls.count == 1)
        #expect(await counter.count == 1)
        _ = await store.applyBankedReset(provider: .claude, id: "yes")
        let calls = await applier.calls
        #expect(calls.count == 2 && calls[0].1 == calls[1].1)
        let another = self.store(snapshot: initial, applier: applier, defaults: defaults)
        another.claude = initial
        _ = await another.applyBankedReset(provider: .claude, id: "yes")
        #expect(await applier.calls.last?.1 == calls.first?.1)
        store.claude.bankedResets = []
        let empty = self.store(snapshot: snapshot(resets: []), applier: applier, defaults: defaults)
        await empty.refresh(.claude)
        #expect((defaults.dictionary(forKey: "bankedResetIdempotencyKeys") ?? [:]).isEmpty)
    }

    @Test func defaultApplierFailsOfflineAndRemovedRowsRemainUntilRefresh() async throws {
        let suite = "offline-reset-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let counter = CallCounter()
        let empty = snapshot(resets: [])
        let store = UsageStore(claudeProbe: CountingProbe(snapshot: empty, counter: counter),
            codexProbe: CountingProbe(snapshot: makeSnapshot(.codex), counter: CallCounter()),
            userDefaults: defaults, startRefreshLoop: false)
        store.claude = snapshot(resets: [.init(id: "id", title: "Full", usable: true)])
        let result = await store.applyBankedReset(provider: .claude, id: "id")
        #expect(result.outcome == .error)
        #expect(await counter.count == 1)
        #expect(store.bankedResetResultRows["claude:id"]?.title == "Full")
        #expect(store.bankedResetResultRows["claude:id"]?.usable == false)
        #expect(store.bankedResetMessages["claude:id"] == result.message)
        await store.refresh(.claude)
        #expect(store.bankedResetResultRows.isEmpty && store.bankedResetMessages.isEmpty)
    }

    @Test func failedReadsKeepLastKnownResets() async throws {
        let suite = "failed-read-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let failure = makeSnapshot(.claude, fiveHourMessage: "Claude usage endpoint returned HTTP 500.")
        let store = UsageStore(claudeProbe: CountingProbe(snapshot: failure, counter: CallCounter()),
            codexProbe: CountingProbe(snapshot: makeSnapshot(.codex), counter: CallCounter()),
            userDefaults: defaults, startRefreshLoop: false)
        store.claude = snapshot(resets: [.init(id: "kept", title: "Full", usable: true)])
        await store.refresh(.claude)
        await store.refresh(.claude)
        #expect(store.claude.fiveHour.usedPercentage == nil)
        #expect(store.claude.bankedResets.map(\.id) == ["kept"])
    }

    @Test func autoApplyOnlyDueResetOnceAndRetryAfterSixtySeconds() async throws {
        let suite = "auto-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let initial = snapshot(resets: [
            .init(id: "due", title: "Due", expiresAt: now.addingTimeInterval(240), usable: true),
            .init(id: "later", title: "Later", expiresAt: now.addingTimeInterval(2000), usable: true),
            .init(id: "never", title: "Never", usable: true),
            .init(id: "expired", title: "Expired", expiresAt: now, usable: true)])
        let applier = ResetApplierSpy(.reset)
        let store = store(snapshot: initial, applier: applier, defaults: defaults)
        store.claude = initial
        #expect(!store.bankedResetAutoApplyEnabled)
        await store.autoApplyTick(now: now)
        #expect(await applier.calls.isEmpty)
        store.bankedResetAutoApplyEnabled = true
        await store.autoApplyTick(now: now)
        await store.autoApplyTick(now: now.addingTimeInterval(61))
        #expect(await applier.calls.map { $0.0 } == ["due"])
        #expect(store.lastAutoApplyResult?.title == "Due")
        let failed = ResetApplierSpy(.unconfirmed)
        let retry = self.store(snapshot: initial, applier: failed, defaults: defaults)
        retry.claude = initial
        await retry.autoApplyTick(now: now)
        await retry.autoApplyTick(now: now.addingTimeInterval(59))
        #expect(await failed.calls.count == 1)
        await retry.autoApplyTick(now: now.addingTimeInterval(60))
        #expect(await failed.calls.count == 2)
        let calls = await failed.calls
        #expect(calls.first?.1 == calls.last?.1)
        retry.bankedResetAutoApplyLeadMinutes = 100
        #expect(retry.bankedResetAutoApplyLeadMinutes == 60)
        retry.bankedResetAutoApplyLeadMinutes = 0
        #expect(retry.bankedResetAutoApplyLeadMinutes == 1)
    }

    @Test func autoApplyRechecksFreshListing() async throws {
        let defaults = try #require(UserDefaults(suiteName: "recheck-\(UUID().uuidString)"))
        let applier = ResetApplierSpy(.reset)
        let now = Date.now
        let store = store(snapshot: snapshot(resets: []), applier: applier, defaults: defaults)
        store.claude = snapshot(resets: [.init(id: "gone", title: "Gone", expiresAt: now.addingTimeInterval(10), usable: true)])
        store.bankedResetAutoApplyEnabled = true
        await store.autoApplyTick(now: now)
        #expect(await applier.calls.isEmpty)
    }

    @Test(arguments: [BankedResetOutcome.reset, .alreadyRedeemed, .nothingToReset, .noCredit, .cooldown, .ineligible, .unavailable, .rateLimited, .unconfirmed, .error, .notFound, .notUsable])
    func applyRoutesAndStatusCodes(outcome: BankedResetOutcome) async throws {
        let suite = "api-reset-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = snapshot(resets: outcome == .notFound ? [] : [.init(id: "reset_1", title: "Full", usable: outcome != .notUsable)])
        let applier = ResetApplierSpy(outcome)
        let store = store(snapshot: initial, applier: applier, defaults: defaults)
        store.claude = initial
        let server = UsageAPIServer(store: store, userDefaults: defaults, followSettings: false)
        let peer = NWEndpoint.hostPort(host: "127.0.0.1", port: 9000)
        let result = await server.respond(to: "POST /resets/claude/reset%5F1/apply HTTP/1.1", peer: peer)
        #expect(result.status == outcome.httpStatus)
        let body = try #require(try JSONSerialization.jsonObject(with: result.body) as? [String: Any])
        #expect(body["outcome"] as? String == outcome.rawValue)
        #expect(body["reset_id"] as? String == "reset_1")
        #expect(body["applied"] as? Bool == outcome.applied)
        #expect((body["usage"] as? [String: Any])?["banked_resets"] != nil)
        #expect(await server.respond(to: "GET /resets/claude/reset_1/apply HTTP/1.1", peer: peer).status == 405)
        #expect(await server.respond(to: "POST /resets/unknown/reset_1/apply HTTP/1.1", peer: peer).status == 404)
        #expect(UsageAPIResponse(status: 409, body: Data()).statusLine == "409 Conflict")
        #expect(UsageAPIResponse(status: 502, body: Data()).statusLine == "502 Bad Gateway")
    }

    @Test func resetListingOrderAndPayloadKeys() throws {
        let now = Date.now
        let router = UsageAPIRouter(providers: { provider in
            var snapshot = makeSnapshot(provider)
            if provider == .claude { snapshot.bankedResets = [.init(id: "none", title: "No expiry"), .init(id: "late", title: "Late", expiresAt: now)] }
            if provider == .codex { snapshot.bankedResets = [.init(id: "early", title: "Early", expiresAt: now.addingTimeInterval(-60), status: "expired")] }
            return UsageAPIProviderPayload(snapshot: snapshot, updatedAt: nil)
        }, lastUpdated: { nil })
        let response = router.respond(method: "GET", path: "/resets")
        let json = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let resets = try #require(json["resets"] as? [[String: Any]])
        #expect(resets.compactMap { $0["id"] as? String } == ["early", "late", "none"])
        #expect(resets.first?["provider"] as? String == "codex")
        #expect(Set(resets[0].keys) == Set(["provider", "id", "title", "description", "granted_at", "expires_at", "status", "usable", "remaining", "note"]))
        #expect((json["auto_apply"] as? [String: Any])?["enabled"] as? Bool == false)
        let bulk = try #require(try JSONSerialization.jsonObject(with: router.respond(method: "GET", path: "/usage").body) as? [String: Any])
        #expect(bulk["banked_reset_auto_apply"] != nil)
        #expect((bulk["gemini"] as? [String: Any])?["banked_resets"] as? [String] == [])
    }
}
