import Foundation
import Testing
@testable import TokenWatch

@Suite struct ProcessRunnerTests {

    // MARK: - expandUserPath

    @Test func expandUserPath() {
        #expect(ProcessRunner.expandUserPath("~", homeDirectory: "/Users/test") == "/Users/test")
        #expect(ProcessRunner.expandUserPath("~/x", homeDirectory: "/Users/test") == "/Users/test/x")
        #expect(ProcessRunner.expandUserPath("/abs/path", homeDirectory: "/Users/test") == "/abs/path")
        #expect(ProcessRunner.expandUserPath("~user", homeDirectory: "/Users/test") == "~user")
    }

    // MARK: - pathDirectories

    @Test func pathDirectories() {
        let dirs = ProcessRunner.pathDirectories(
            environment: ["PATH": "/a:/b:/a"],
            loginShellPath: "/c:/d",
            homeDirectory: "/home/x"
        )

        // Order + dedup of PATH entries.
        let ai = try! #require(dirs.firstIndex(of: "/a"))
        let bi = try! #require(dirs.firstIndex(of: "/b"))
        #expect(ai < bi)
        #expect(dirs.filter { $0 == "/a" }.count == 1)

        // Login-shell path entries included.
        #expect(dirs.contains("/c"))
        #expect(dirs.contains("/d"))

        // Standard fallbacks appended and tilde-expanded against the given home.
        #expect(dirs.contains("/opt/homebrew/bin"))
        #expect(dirs.contains("/usr/local/bin"))
        #expect(dirs.contains("/usr/bin"))
        #expect(dirs.contains("/bin"))
        #expect(dirs.contains("/home/x/bin"))
        #expect(dirs.contains("/home/x/.local/bin"))
        #expect(!dirs.contains("~/bin"))
    }

    // MARK: - environment(base:pathDirectories:)

    @Test func environmentOverridesPathOnly() {
        let env = ProcessRunner.environment(base: ["PATH": "/old", "FOO": "bar"], pathDirectories: ["/x", "/y"])
        #expect(env["PATH"] == "/x:/y")
        #expect(env["FOO"] == "bar")
    }

    // MARK: - which(_:directories:)

    @Test func whichFindsExecutable() throws {
        let dir = try makeTemporaryDirectory()
        let tool = dir.appendingPathComponent("mytool")
        try "#!/bin/sh\necho hi\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        #expect(ProcessRunner.which("mytool", directories: [dir.path]) == tool.path)
        #expect(ProcessRunner.which("does-not-exist", directories: [dir.path]) == nil)
    }

    // MARK: - runSync

    @Test func runSyncEchoReturnsStdout() throws {
        let out = try ProcessRunner.runSync(
            executable: "/bin/echo",
            arguments: ["hello"],
            input: nil,
            timeout: nil,
            currentDirectory: nil
        )
        #expect(out.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }

    @Test func runSyncNonZeroThrowsTerminated() {
        do {
            _ = try ProcessRunner.runSync(
                executable: "/bin/sh",
                arguments: ["-c", "exit 3"],
                input: nil,
                timeout: nil,
                currentDirectory: nil
            )
            Issue.record("expected a thrown error")
        } catch let ProcessRunnerError.terminated(status, _) {
            #expect(status == 3)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func runSyncFalseThrows() {
        #expect(throws: ProcessRunnerError.self) {
            _ = try ProcessRunner.runSync(
                executable: "/usr/bin/false",
                arguments: [],
                input: nil,
                timeout: nil,
                currentDirectory: nil
            )
        }
    }

    @Test func runSyncPassesStdin() throws {
        let out = try ProcessRunner.runSync(
            executable: "/bin/cat",
            arguments: [],
            input: "piped",
            timeout: nil,
            currentDirectory: nil
        )
        #expect(out.contains("piped"))
    }

    @Test func runSyncTimeoutDoesNotHang() {
        let start = Date()
        _ = try? ProcessRunner.runSync(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 5"],
            input: nil,
            timeout: 0.3,
            currentDirectory: nil
        )
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 3)
    }
}
