import Foundation

// MARK: - Support Types

struct CodexRateLimitWindow: Sendable, Equatable {
    let usedPercent: Double
    let resetsAt: Date?
    let windowDurationMins: Double?

    init(usedPercent: Double, resetsAt: Date? = nil, windowDurationMins: Double? = nil) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowDurationMins = windowDurationMins
    }
}

struct CodexRateLimits: Sendable, Equatable {
    let fiveHour: CodexRateLimitWindow?
    let weekly: CodexRateLimitWindow?
    let planType: String?

    init(fiveHour: CodexRateLimitWindow? = nil, weekly: CodexRateLimitWindow? = nil, planType: String? = nil) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.planType = planType
    }
}

// MARK: - CodexProbe

struct CodexProbe: Sendable {
    init() {}

    func fetch() async -> ProviderSnapshot {
        do {
            guard let codexPath = ProcessRunner.which("codex") else {
                throw ProcessRunnerError.executableNotFound("codex")
            }

            let process = Process()
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: codexPath)
            process.arguments = ["-s", "read-only", "app-server"]
            process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.homeDirectoryForCurrentUser.path)
            process.environment = ProcessRunner.environment()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = FileHandle.nullDevice

            try process.run()

            defer {
                try? stdinPipe.fileHandleForWriting.close()
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                }
            }

            let stdinHandle = stdinPipe.fileHandleForWriting
            let stdoutLines = stdoutPipe.fileHandleForReading.bytes.lines

            let initRequest: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "tokenwatch",
                        "version": "0.1.0"
                    ]
                ]
            ]
            try writeJSONLine(initRequest, to: stdinHandle)
            _ = try await readResponse(withID: 1, from: stdoutLines)

            let initializedNotification: [String: Any] = [
                "jsonrpc": "2.0",
                "method": "initialized",
                "params": [:]
            ]
            try writeJSONLine(initializedNotification, to: stdinHandle)

            let rateLimitsRequest: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "account/rateLimits/read",
                "params": [:]
            ]
            try writeJSONLine(rateLimitsRequest, to: stdinHandle)
            let response2 = try await readResponse(withID: 2, from: stdoutLines)

            guard let result = response2["result"] as? [String: Any],
                  let rateLimits = result["rateLimits"] as? [String: Any] else {
                throw ProcessRunnerError.invalidResponse("Codex rate limit response was missing result.rateLimits.")
            }

            let primaryWindow = parseWindow(rateLimits["primary"])
            let secondaryWindow = parseWindow(rateLimits["secondary"])
            let planType = rateLimits["planType"] as? String

            let limits = classifyWindows(primary: primaryWindow, secondary: secondaryWindow, planType: planType)

            let fiveHourWindow: UsageWindow
            if let five = limits.fiveHour {
                fiveHourWindow = UsageWindow(
                    kind: .fiveHour,
                    usedPercentage: five.usedPercent,
                    resetsAt: five.resetsAt,
                    message: nil
                )
            } else {
                fiveHourWindow = UsageWindow(
                    kind: .fiveHour,
                    usedPercentage: nil,
                    resetsAt: nil,
                    message: "No 5h limit returned."
                )
            }

            let weeklyWindow: UsageWindow
            if let w = limits.weekly {
                weeklyWindow = UsageWindow(
                    kind: .weekly,
                    usedPercentage: w.usedPercent,
                    resetsAt: w.resetsAt,
                    message: nil
                )
            } else {
                weeklyWindow = UsageWindow(
                    kind: .weekly,
                    usedPercentage: nil,
                    resetsAt: nil,
                    message: "No weekly limit returned."
                )
            }

            let detail: String? = limits.planType.map { "Plan: \($0)" }

            return ProviderSnapshot(
                provider: .codex,
                fiveHour: fiveHourWindow,
                weekly: weeklyWindow,
                modelWindows: [],
                detail: detail
            )
        } catch {
            let msg = error.localizedDescription
            return ProviderSnapshot(
                provider: .codex,
                fiveHour: UsageWindow(kind: .fiveHour, usedPercentage: nil, resetsAt: nil, message: msg),
                weekly: UsageWindow(kind: .weekly, usedPercentage: nil, resetsAt: nil, message: msg),
                modelWindows: [],
                detail: nil
            )
        }
    }

    func classifyWindows(
        primary: CodexRateLimitWindow?,
        secondary: CodexRateLimitWindow?,
        planType: String?
    ) -> CodexRateLimits {
        TokenWatch_classifyWindows(primary: primary, secondary: secondary, planType: planType)
    }

    func parseWindow(_ value: Any?) -> CodexRateLimitWindow? {
        TokenWatch_parseWindow(value)
    }

    func numericValue(_ value: Any?) -> Double? {
        TokenWatch_numericValue(value)
    }
}

// MARK: - Free Functions & Helper Functions

func classifyWindows(
    primary: CodexRateLimitWindow?,
    secondary: CodexRateLimitWindow?,
    planType: String?
) -> CodexRateLimits {
    TokenWatch_classifyWindows(primary: primary, secondary: secondary, planType: planType)
}

func parseWindow(_ value: Any?) -> CodexRateLimitWindow? {
    TokenWatch_parseWindow(value)
}

func numericValue(_ value: Any?) -> Double? {
    TokenWatch_numericValue(value)
}

private func TokenWatch_classifyWindows(
    primary: CodexRateLimitWindow?,
    secondary: CodexRateLimitWindow?,
    planType: String?
) -> CodexRateLimits {
    let inputs = [primary, secondary].compactMap { $0 }

    var fiveHourSlot: CodexRateLimitWindow? = nil
    var weeklySlot: CodexRateLimitWindow? = nil

    var unassigned: [CodexRateLimitWindow] = []

    for window in inputs {
        if let duration = window.windowDurationMins {
            if duration <= 720 {
                if fiveHourSlot == nil {
                    fiveHourSlot = window
                }
            } else {
                if weeklySlot == nil {
                    weeklySlot = window
                }
            }
        } else {
            unassigned.append(window)
        }
    }

    for window in unassigned {
        if fiveHourSlot == nil {
            fiveHourSlot = window
        } else if weeklySlot == nil {
            weeklySlot = window
        }
    }

    return CodexRateLimits(
        fiveHour: fiveHourSlot,
        weekly: weeklySlot,
        planType: planType
    )
}

private func TokenWatch_parseWindow(_ value: Any?) -> CodexRateLimitWindow? {
    guard let dict = value as? [String: Any] else { return nil }
    guard let usedPercent = numericValue(dict["usedPercent"]) else { return nil }

    let resetsAt: Date?
    if let resetsSeconds = numericValue(dict["resetsAt"]) {
        resetsAt = Date(timeIntervalSince1970: resetsSeconds)
    } else {
        resetsAt = nil
    }

    let durationMins = numericValue(dict["windowDurationMins"])
    return CodexRateLimitWindow(
        usedPercent: usedPercent,
        resetsAt: resetsAt,
        windowDurationMins: durationMins
    )
}

private func TokenWatch_numericValue(_ value: Any?) -> Double? {
    if let double = value as? Double {
        return double
    }
    if let int = value as? Int {
        return Double(int)
    }
    if let number = value as? NSNumber {
        return number.doubleValue
    }
    if let string = value as? String {
        return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return nil
}

func writeJSONLine(_ object: [String: Any], to handle: FileHandle) throws {
    let data = try JSONSerialization.data(withJSONObject: object)
    try handle.write(contentsOf: data)
    try handle.write(contentsOf: Data([0x0A]))
}

func readResponse<S: AsyncSequence>(
    withID id: Int,
    from lines: S
) async throws -> [String: Any] where S.Element == String {
    for try await line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }

        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            continue
        }

        if let messageID = integerValue(json["id"]), messageID == id {
            if let errorObj = json["error"] as? [String: Any],
               let errorMessage = errorObj["message"] as? String {
                throw ProcessRunnerError.invalidResponse(errorMessage)
            } else if let errorMessage = json["error"] as? String {
                throw ProcessRunnerError.invalidResponse(errorMessage)
            }
            return json
        }
    }

    throw ProcessRunnerError.invalidResponse("Codex app-server closed before returning response id \(id).")
}

func integerValue(_ value: Any?) -> Int? {
    if let int = value as? Int {
        return int
    }
    if let number = value as? NSNumber {
        return number.intValue
    }
    if let string = value as? String {
        return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return nil
}
