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
