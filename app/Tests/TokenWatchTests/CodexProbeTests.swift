import Darwin
import Foundation
import Testing
@testable import TokenWatch

@Suite struct CodexProbeTests {

    private func window(_ duration: Double?, used: Double = 10) -> CodexRateLimitWindow {
        CodexRateLimitWindow(usedPercent: used, resetsAt: nil, windowDurationMins: duration)
    }

    private func lineStream(_ lines: [String]) -> AsyncStream<String> {
        AsyncStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }

    @Test func fetchCompletesHandshakeAndReturnsWeeklyUsage() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex")
        let script = #"""
        #!/bin/sh
        IFS= read -r initialize
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r initialized
        IFS= read -r request
        printf '%s\n' '{"method":"account/updated","params":{}}'
        printf '%s\n' '{"id":2,"result":{"rateLimits":{"planType":"pro","primary":{"usedPercent":27,"windowDurationMins":10080,"resetsAt":1790716921},"secondary":null}}}'
        while IFS= read -r line; do :; done
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let snapshot = await CodexProbe(executablePath: executable.path).fetch()
        #expect(snapshot.weekly.usedPercentage == 27)
        #expect(snapshot.weekly.resetsAt == Date(timeIntervalSince1970: 1790716921))
        #expect(snapshot.fiveHour.usedPercentage == nil)
        #expect(snapshot.detail == "Plan: pro")
    }

    private func executable(in directory: URL, script: String) throws -> URL {
        let executable = directory.appendingPathComponent("codex")
        try ("#!/bin/sh\n" + script).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    @Test(arguments: [false, true])
    func fetchTimesOutAndKillsUnresponsiveProcess(afterInitialize: Bool) async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = """
        trap '' TERM
        printf '%s' "$$" > "$0.pid"
        IFS= read -r initialize
        \(afterInitialize ? "printf '%s\\n' '{\"id\":1,\"result\":{}}'" : ":")
        while IFS= read -r line; do :; done
        while :; do :; done
        """
        let path = try executable(in: directory, script: script)
        let started = ContinuousClock.now
        let snapshot = await CodexProbe(executablePath: path.path, timeout: 1).fetch()

        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(snapshot.weekly.usedPercentage == nil)
        #expect(snapshot.weekly.message == "Codex app-server timed out. Try refreshing again.")
        let pidText = try String(contentsOf: path.appendingPathExtension("pid"), encoding: .utf8)
        let pid = try #require(Int32(pidText))
        let exited = await waitUntil { kill(pid, 0) == -1 && errno == ESRCH }
        #expect(exited)
    }

    @Test func cancellationStopsAStalledFetch() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = try executable(in: directory, script: #"""
        printf '%s' "$$" > "$0.pid"
        while IFS= read -r line; do :; done
        """#)
        let task = Task { await CodexProbe(executablePath: path.path, timeout: 20).fetch() }
        let launched = await waitUntil {
            FileManager.default.fileExists(atPath: path.appendingPathExtension("pid").path)
        }
        #expect(launched)
        let started = ContinuousClock.now
        task.cancel()
        let snapshot = await task.value
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(snapshot.weekly.usedPercentage == nil)
        let pidText = try String(contentsOf: path.appendingPathExtension("pid"), encoding: .utf8)
        let pid = try #require(Int32(pidText))
        let exited = await waitUntil { kill(pid, 0) == -1 && errno == ESRCH }
        #expect(exited)
    }

    @Test @MainActor func refreshRecoversAfterCodexTimeout() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = try executable(in: directory, script: #"""
        IFS= read -r initialize
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r initialized
        IFS= read -r request
        if [ ! -f "$0.ready" ]; then
            printf ready > "$0.ready"
            while IFS= read -r line; do :; done
        else
            printf '%s\n' '{"id":2,"result":{"rateLimits":{"planType":"pro","primary":{"usedPercent":27,"windowDurationMins":10080}}}}'
            while IFS= read -r line; do :; done
        fi
        """#)
        let suite = "codex-recovery-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(
            claudeProbe: ProbeStub(queue: ProbeQueue([makeSnapshot(.claude, fiveHourUsed: 10)])),
            codexProbe: CodexProbe(executablePath: path.path, timeout: 1),
            userDefaults: defaults,
            startRefreshLoop: false
        )

        await store.refresh()
        #expect(!store.isRefreshing)
        #expect(store.codex.weekly.message == "Codex app-server timed out. Try refreshing again.")
        #expect(store.claude.fiveHour.usedPercentage == 10)
        let failedAt = try #require(store.lastUpdatedByProvider[.codex])

        await store.refresh(.codex)
        #expect(!store.isRefreshing)
        #expect(store.codex.weekly.usedPercentage == 27)
        #expect(store.codex.fiveHour.usedPercentage == nil)
        #expect(try #require(store.lastUpdatedByProvider[.codex]) > failedAt)
    }

    @Test func fetchHandlesFragmentedResponse() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = try executable(in: directory, script: #"""
        IFS= read -r initialize
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r initialized
        IFS= read -r request
        printf '%s\n' 'not JSON' '{"method":"account/updated","params":{}}'
        printf '%s' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":12,'
        sleep 0.05
        printf '%s\n' '"windowDurationMins":10080}}}}'
        while IFS= read -r line; do :; done
        """#)
        let snapshot = await CodexProbe(executablePath: path.path).fetch()
        #expect(snapshot.weekly.usedPercentage == 12)
    }

    // MARK: - classifyWindows

    @Test func classifyByDurationRegardlessOfOrder() {
        let probe = CodexProbe()

        let a = probe.classifyWindows(primary: window(300), secondary: window(10_080), planType: "pro")
        #expect(a.fiveHour?.windowDurationMins == 300)
        #expect(a.weekly?.windowDurationMins == 10_080)
        #expect(a.planType == "pro")

        let b = probe.classifyWindows(primary: window(10_080), secondary: window(300), planType: "pro")
        #expect(b.fiveHour?.windowDurationMins == 300)
        #expect(b.weekly?.windowDurationMins == 10_080)
    }

    @Test func classifySingleWeeklyPrimary() {
        let probe = CodexProbe()
        let result = probe.classifyWindows(primary: window(10_080), secondary: nil, planType: nil)
        #expect(result.fiveHour == nil)
        #expect(result.weekly?.windowDurationMins == 10_080)
    }

    @Test func classifyNoDurationsPositional() {
        let probe = CodexProbe()
        let result = probe.classifyWindows(primary: window(nil, used: 1), secondary: window(nil, used: 2), planType: nil)
        #expect(result.fiveHour?.usedPercent == 1)
        #expect(result.weekly?.usedPercent == 2)
    }

    // MARK: - parseWindow

    @Test func parseWindowFromNumericStrings() {
        let probe = CodexProbe()
        let dict: [String: Any] = ["usedPercent": "12.5", "resetsAt": "1700000000", "windowDurationMins": "300"]
        let window = probe.parseWindow(dict)
        #expect(window?.usedPercent == 12.5)
        #expect(window?.resetsAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(window?.windowDurationMins == 300)
    }

    @Test func parseWindowMissingUsedPercent() {
        let probe = CodexProbe()
        #expect(probe.parseWindow(["resetsAt": "1"] as [String: Any]) == nil)
    }

    @Test func parseWindowNonDict() {
        let probe = CodexProbe()
        #expect(probe.parseWindow("not a dict") == nil)
        #expect(probe.parseWindow(nil) == nil)
    }

    // MARK: - numericValue / integerValue

    @Test func numericValueAcceptsAndRejects() {
        let probe = CodexProbe()
        #expect(probe.numericValue(5) == 5.0)
        #expect(probe.numericValue(2.5) == 2.5)
        #expect(probe.numericValue(NSNumber(value: 3)) == 3.0)
        #expect(probe.numericValue("4.5") == 4.5)
        #expect(probe.numericValue("abc") == nil)
        #expect(probe.numericValue(nil) == nil)
    }

    @Test func integerValueAcceptsAndRejects() {
        #expect(integerValue(5) == 5)
        #expect(integerValue(NSNumber(value: 3)) == 3)
        #expect(integerValue("7") == 7)
        #expect(integerValue("x") == nil)
        #expect(integerValue(nil) == nil)
    }

    // MARK: - readResponse

    @Test func readResponseReturnsMatchingID() async throws {
        let lines = [
            "",
            #"{"jsonrpc":"2.0","id":1,"result":{}}"#,
            "not json",
            #"{"jsonrpc":"2.0","id":2,"result":{"ok":true}}"#,
        ]
        let object = try await readResponse(withID: 2, from: lineStream(lines))
        #expect(object["id"] as? Int == 2)
        #expect((object["result"] as? [String: Any])?["ok"] as? Bool == true)
    }

    @Test func readResponseThrowsServerError() async {
        let lines = [#"{"id":2,"error":{"message":"boom"}}"#]
        do {
            _ = try await readResponse(withID: 2, from: lineStream(lines))
            Issue.record("expected a thrown error")
        } catch let ProcessRunnerError.invalidResponse(message) {
            #expect(message == "boom")
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func readResponseThrowsWhenStreamEnds() async {
        let lines = [#"{"id":1,"result":{}}"#]
        do {
            _ = try await readResponse(withID: 2, from: lineStream(lines))
            Issue.record("expected a thrown error")
        } catch let ProcessRunnerError.invalidResponse(message) {
            #expect(message == "Codex app-server closed before returning response id 2.")
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    // MARK: - writeJSONLine

    @Test func writeJSONLineAppendsNewline() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("out.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try writeJSONLine(["a": 1], to: handle)
        try handle.close()

        let data = try Data(contentsOf: url)
        #expect(data.last == 0x0A)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["a"] as? Int == 1)
    }
}
