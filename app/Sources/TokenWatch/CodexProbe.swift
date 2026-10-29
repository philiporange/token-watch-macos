import Darwin
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
    private let executablePath: String?
    private let timeout: TimeInterval

    init(executablePath: String? = nil, timeout: TimeInterval = 20) {
        self.executablePath = executablePath
        self.timeout = timeout
    }

    func fetch() async -> ProviderSnapshot {
        let cancellation = CodexRequestCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: fetchSync(cancellation: cancellation))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func fetchSync(cancellation: CodexRequestCancellation) -> ProviderSnapshot {
        do {
            let response2 = try codexRequestSync(executablePath: executablePath, timeout: timeout,
                                                 method: "account/rateLimits/read", params: [:], cancellation: cancellation)
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
                detail: detail,
                bankedResets: Self.parseBankedResets(result["rateLimitResetCredits"])
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

/// Shares cancellation with the worker that owns the subprocess and its pipes.
private final class CodexRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.withLock { cancelled = true }
    }

    func check() throws {
        if lock.withLock({ cancelled }) {
            throw CancellationError()
        }
    }
}

/// Reads complete JSON lines with a deadline, preserving buffered data between responses.
private struct CodexResponseReader {
    let handle: FileHandle
    let deadline: ContinuousClock.Instant
    let cancellation: CodexRequestCancellation
    private var buffer = Data()

    init(handle: FileHandle, deadline: ContinuousClock.Instant, cancellation: CodexRequestCancellation) {
        self.handle = handle
        self.deadline = deadline
        self.cancellation = cancellation
    }

    mutating func readResponse(withID id: Int) throws -> [String: Any] {
        while true {
            try cancellation.check()
            guard ContinuousClock.now < deadline else {
                throw CodexReadInterruption(detail: "Codex app-server timed out. Try refreshing again.")
            }

            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                if let response = try codexResponse(from: line, withID: id) {
                    return response
                }
                continue
            }

            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 50)
            if ready < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if ready == 0 { continue }

            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = read(handle.fileDescriptor, &bytes, bytes.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard count > 0 else {
                throw CodexReadInterruption(detail: "Codex app-server closed before returning response id \(id).")
            }
            buffer.append(contentsOf: bytes.prefix(count))
        }
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
        if let response = try codexResponse(from: line, withID: id) {
            return response
        }
    }

    throw ProcessRunnerError.invalidResponse("Codex app-server closed before returning response id \(id).")
}

private func codexResponse(from line: String, withID id: Int) throws -> [String: Any]? {
    guard let data = line.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          integerValue(json["id"]) == id else {
        return nil
    }

    if let errorObj = json["error"] as? [String: Any],
       let errorMessage = errorObj["message"] as? String {
        throw ProcessRunnerError.invalidResponse(errorMessage)
    } else if let errorMessage = json["error"] as? String {
        throw ProcessRunnerError.invalidResponse(errorMessage)
    }
    return json
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

private struct CodexReadInterruption: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}

struct CodexConsumeFailure: LocalizedError {
    let requestWritten: Bool
    let detail: String
    var errorDescription: String? { detail }
}

private func codexRequestSync(executablePath: String?, timeout: TimeInterval, method: String,
                              params: [String: String], cancellation: CodexRequestCancellation) throws -> [String: Any] {
    try cancellation.check()
    let directories = ProcessRunner.pathDirectories()
    guard let codexPath = executablePath ?? ProcessRunner.which("codex", directories: directories) else {
        throw ProcessRunnerError.executableNotFound("codex")
    }

    let process = Process()
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()

    process.executableURL = URL(fileURLWithPath: codexPath)
    process.arguments = ["-s", "read-only", "app-server"]
    process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.homeDirectoryForCurrentUser.path)
    process.environment = ProcessRunner.environment(
        base: ProcessInfo.processInfo.environment,
        pathDirectories: directories
    )
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = FileHandle.nullDevice

    try process.run()

    defer {
        try? stdinPipe.fileHandleForWriting.close()
        try? stdoutPipe.fileHandleForReading.close()
        if process.isRunning {
            process.terminate()
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
            while process.isRunning && ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    let stdinHandle = stdinPipe.fileHandleForWriting
    var reader = CodexResponseReader(
        handle: stdoutPipe.fileHandleForReading,
        deadline: ContinuousClock.now.advanced(by: .seconds(max(0, timeout))),
        cancellation: cancellation
    )

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
    _ = try reader.readResponse(withID: 1)

    let initializedNotification: [String: Any] = [
        "jsonrpc": "2.0",
        "method": "initialized",
        "params": [:]
    ]
    try writeJSONLine(initializedNotification, to: stdinHandle)

    let request: [String: Any] = [
        "jsonrpc": "2.0",
        "id": 2,
        "method": method,
        "params": params
    ]
    try writeJSONLine(request, to: stdinHandle)
    do {
        return try reader.readResponse(withID: 2)
    } catch let error as CodexReadInterruption {
        throw CodexConsumeFailure(requestWritten: true, detail: error.localizedDescription)
    }
}

protocol CodexResetTransport: Sendable {
    func consume(id: String, idempotencyKey: String) async throws -> Data
}

struct CodexLiveResetTransport: CodexResetTransport {
    func consume(id: String, idempotencyKey: String) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let response = try codexRequestSync(executablePath: nil, timeout: 30,
                method: "account/rateLimitResetCredit/consume",
                params: ["creditId": id, "idempotencyKey": idempotencyKey], cancellation: CodexRequestCancellation())
            return try JSONSerialization.data(withJSONObject: response)
        }.value
    }
}

struct CodexBankedResetApplier: BankedResetApplying {
    let transport: any CodexResetTransport

    func apply(id: String, idempotencyKey: String) async -> BankedResetUpstreamResult {
        do {
            let data = try await transport.consume(id: id, idempotencyKey: idempotencyKey)
            let response = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let error = response?["error"] {
                return .init(outcome: .error, detail: String(describing: error))
            }
            let result = response?["result"] as? [String: Any]
            switch result?["outcome"] as? String {
            case "reset": return .init(outcome: .reset)
            case "nothingToReset": return .init(outcome: .nothingToReset)
            case "noCredit": return .init(outcome: .noCredit)
            case "alreadyRedeemed": return .init(outcome: .alreadyRedeemed)
            default: return .init(outcome: .error, detail: "Invalid consume response.")
            }
        } catch let error as CodexConsumeFailure {
            return .init(outcome: error.requestWritten ? .unconfirmed : .error, detail: error.detail)
        } catch {
            return .init(outcome: .error, detail: error.localizedDescription)
        }
    }
}

extension CodexProbe {
    static func parseBankedResets(_ value: Any?, now: Date = .now) -> [BankedReset] {
        guard let block = value as? [String: Any], let credits = block["credits"] as? [[String: Any]] else { return [] }
        return credits.compactMap { credit in
            guard let id = credit["id"] as? String, BankedReset.validID(id) else { return nil }
            let expiry = TokenWatch_numericValue(credit["expiresAt"]).map(Date.init(timeIntervalSince1970:))
            let raw = credit["status"] as? String ?? "unknown"
            let status = expiry.map { $0 <= now } == true ? "expired" :
                (["available", "redeeming", "redeemed"].contains(raw) ? raw : "unknown")
            return BankedReset(id: id, title: credit["title"] as? String ?? "Codex reset",
                detail: credit["description"] as? String,
                grantedAt: TokenWatch_numericValue(credit["grantedAt"]).map(Date.init(timeIntervalSince1970:)),
                expiresAt: expiry, status: status, usable: status == "available", remaining: status == "available" ? 1 : 0)
        }
    }
}
