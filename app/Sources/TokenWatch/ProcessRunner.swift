import Foundation

enum ProcessRunnerError: LocalizedError {
    case executableNotFound(String)
    case terminated(Int32, String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case let .executableNotFound(name):
            return "\(name) is not installed or not on PATH."
        case let .terminated(status, output):
            return output.isEmpty ? "Process exited with status \(status)." : output
        case let .invalidResponse(message):
            return message
        }
    }
}

enum ProcessRunner {
    static func which(_ executable: String) -> String? {
        which(executable, directories: pathDirectories())
    }

    static func which(_ executable: String, directories: [String]) -> String? {
        let fileManager = FileManager.default

        for directory in directories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(executable, isDirectory: false)
                .path

            guard fileManager.isExecutableFile(atPath: candidate) else {
                continue
            }

            return candidate
        }

        return nil
    }

    static func environment() -> [String: String] {
        environment(
            base: ProcessInfo.processInfo.environment,
            pathDirectories: pathDirectories()
        )
    }

    static func environment(
        base: [String: String],
        pathDirectories: [String]
    ) -> [String: String] {
        var result = base
        result["PATH"] = pathDirectories.joined(separator: ":")
        return result
    }

    static func pathDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        loginShellPath: String? = ProcessRunner.loginShellPath(),
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String] {
        let fallbackDirectories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "~/bin",
            "~/.local/bin"
        ]

        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        let shellPathEntries = (loginShellPath ?? "")
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        let allEntries = pathEntries + shellPathEntries + fallbackDirectories

        var result: [String] = []
        var seen = Set<String>()

        for entry in allEntries {
            guard !entry.isEmpty else { continue }

            let expandedEntry = expandUserPath(String(entry), homeDirectory: homeDirectory)
            guard !expandedEntry.isEmpty, seen.insert(expandedEntry).inserted else {
                continue
            }

            result.append(expandedEntry)
        }

        return result
    }

    private static func loginShellPath() -> String? {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let configuredShell = environment["SHELL"]
        let candidates: [String] = [configuredShell, "/bin/zsh", "/bin/bash"].compactMap { shell in
            guard let shell, !shell.isEmpty else { return nil }
            return shell
        }

        for shell in candidates where fileManager.isExecutableFile(atPath: shell) {
            let process = Process()
            let outputPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-l", "-c", "printf %s \"$PATH\""]
            process.currentDirectoryURL = URL(fileURLWithPath: fileManager.homeDirectoryForCurrentUser.path)
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()

                guard process.terminationStatus == 0 else { continue }

                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty {
                    return path
                }
            } catch {
                continue
            }
        }

        return nil
    }

    static func expandUserPath(
        _ path: String,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        if path == "~" {
            return homeDirectory
        }

        if path.hasPrefix("~/") {
            return homeDirectory + String(path.dropFirst())
        }

        return path
    }

    static func run(
        executable: String,
        arguments: [String],
        input: String? = nil,
        timeout: TimeInterval = 20,
        currentDirectory: URL? = nil
    ) async throws -> String {
        guard let resolvedExecutable = which(executable) else {
            throw ProcessRunnerError.executableNotFound(executable)
        }

        return try await Task.detached(priority: .utility) {
            try runSync(
                executable: resolvedExecutable,
                arguments: arguments,
                input: input,
                timeout: timeout,
                currentDirectory: currentDirectory
            )
        }.value
    }

    static func runSync(
        executable: String,
        arguments: [String],
        input: String?,
        timeout: TimeInterval?,
        currentDirectory: URL?
    ) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = inputPipe
        process.currentDirectoryURL = currentDirectory

        try process.run()

        let inputHandle = inputPipe.fileHandleForWriting
        do {
            if let input {
                try inputHandle.write(contentsOf: Data(input.utf8))
            }
            try inputHandle.close()
        } catch {
            try? inputHandle.close()
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            throw error
        }

        if let timeout {
            let deadline = Date().addingTimeInterval(max(0, timeout))

            while process.isRunning {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { break }
                Thread.sleep(forTimeInterval: min(0.05, remaining))
            }

            if process.isRunning {
                process.terminate()

                let terminationDeadline = Date().addingTimeInterval(0.25)
                while process.isRunning {
                    let remaining = terminationDeadline.timeIntervalSinceNow
                    guard remaining > 0 else { break }
                    Thread.sleep(forTimeInterval: min(0.05, remaining))
                }

                if process.isRunning {
                    process.interrupt()
                }
            }

            process.waitUntilExit()
        } else {
            process.waitUntilExit()
        }

        let stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(decoding: stdoutData, as: UTF8.self)
        let stderr = String(decoding: stderrData, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw ProcessRunnerError.terminated(
                process.terminationStatus,
                stderr.isEmpty ? stdout : stderr
            )
        }

        return stdout
    }
}
