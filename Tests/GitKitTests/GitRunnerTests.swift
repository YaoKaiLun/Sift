import XCTest
@testable import GitKit

final class GitRunnerTests: XCTestCase {
    /// Apple Git 的 `git daemon` 无 `--foreground` / `--port=0`；不传 `--detach` 就会前台挂起。
    private static func hangingDaemonArguments() -> [String] {
        [
            "daemon",
            "--reuseaddr",
            "--listen=127.0.0.1",
            "--port=\(Int.random(in: 20_000...49_000))",
            "--base-path=.",
            "--export-all",
            "--verbose",
            "--log-destination=stderr",
        ]
    }

    func testRunReturnsStdout() async throws {
        let repo = try FixtureRepo()
        try repo.write("x\n", to: "a.txt")
        try repo.commit("initial")

        let runner = GitRunner()
        let data = try await runner.run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo.url)
        let branch = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(branch, "main")
    }

    func testNonZeroExitThrows() async throws {
        let repo = try FixtureRepo()
        let runner = GitRunner()
        do {
            _ = try await runner.run(["cat-file", "-p", "doesnotexist"], in: repo.url)
            XCTFail("期望抛出 nonZeroExit")
        } catch let error as GitError {
            guard case .nonZeroExit = error else {
                return XCTFail("期望 nonZeroExit，实际是 \(error)")
            }
        }
    }

    func testRunAllowingFailureReturnsExitCode() async throws {
        let repo = try FixtureRepo()
        let runner = GitRunner()
        let output = try await runner.runAllowingFailure(["cat-file", "-p", "doesnotexist"], in: repo.url)
        XCTAssertNotEqual(output.exitCode, 0)
        XCTAssertFalse(output.stderr.isEmpty)
    }

    /// 这是最重要的一个测试：git 输出超过管道缓冲区（64KB）时，
    /// 任何"先 waitUntilExit 再读管道"的实现都会死锁。
    func testHandlesOutputLargerThanPipeBuffer() async throws {
        let repo = try FixtureRepo()
        let bigLine = String(repeating: "x", count: 100)
        let bigContent = (0..<20_000).map { "\($0) \(bigLine)" }.joined(separator: "\n")
        try repo.write(bigContent, to: "big.txt")
        try repo.commit("big file")

        let runner = GitRunner()
        let data = try await runner.run(["show", "HEAD:big.txt"], in: repo.url)
        XCTAssertGreaterThan(data.count, 2_000_000, "期望输出远超管道缓冲区")
    }

    func testTimeoutTerminatesHangingProcess() async throws {
        let repo = try FixtureRepo()
        let runner = GitRunner(timeout: .milliseconds(200))
        do {
            _ = try await runner.run(Self.hangingDaemonArguments(), in: repo.url)
            XCTFail("期望抛出 timedOut")
        } catch let error as GitError {
            guard case .timedOut = error else {
                return XCTFail("期望 timedOut，实际是 \(error)")
            }
        }
    }

    func testLaunchFailureDoesNotHang() async throws {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitRunnerTests-\(UUID().uuidString)")
        try Data().write(to: bogus) // 文件而非目录，Process.run() 会失败

        let runner = GitRunner()
        let start = ContinuousClock.now
        do {
            _ = try await runner.run(["status"], in: bogus)
            XCTFail("expected launchFailed")
        } catch GitError.launchFailed {
            XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testCancellationThrowsCancellationErrorNotTimeout() async throws {
        let repo = try FixtureRepo()
        let repoURL = repo.url
        let runner = GitRunner(timeout: .seconds(30))
        let arguments = Self.hangingDaemonArguments()
        let task = Task<Data, Error>.detached {
            try await runner.run(arguments, in: repoURL)
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        let started = ContinuousClock.now
        do {
            _ = try await task.value
            XCTFail("期望 CancellationError")
        } catch is CancellationError {
            // 取消必须报 CancellationError，不能伪装成超时。
        } catch let error as GitError {
            XCTFail("取消不应抛 GitError（尤其是 timedOut），实际是 \(error)")
        }
        let elapsed = ContinuousClock.now - started
        XCTAssertLessThan(elapsed, Duration.seconds(2), "取消后应在约 2 秒内返回")
    }

    func testStdinIsHashedByGit() async throws {
        let repo = try FixtureRepo()
        let runner = GitRunner()
        let data = try await runner.run(
            ["hash-object", "--stdin"], in: repo.url,
            stdin: Data("hello\n".utf8))
        let hash = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(hash.count, 40)
    }

    func testStdinApplyStagesHunk() async throws {
        let repo = try FixtureRepo()
        try repo.write("line1\nline2\nline3\n", to: "a.txt")
        try repo.commit("initial")
        try repo.write("line1\nCHANGED\nline3\n", to: "a.txt")

        let diffData = try await GitRunner().run(
            ["diff", "--no-color", "-U3", "--", "a.txt"], in: repo.url)
        let diff = DiffParser.parse(diffData, path: "a.txt")
        let hunk = try XCTUnwrap(diff.hunks.first)
        let patch = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        \(hunk.patchText)
        """

        try repo.git("checkout", "--", "a.txt")
        _ = try await GitRunner().run(
            ["apply", "--cached"], in: repo.url,
            stdin: Data(patch.utf8), optionalLocks: false)

        let staged = try await GitRunner().run(
            ["diff", "--cached", "--name-only"], in: repo.url)
        XCTAssertTrue(String(decoding: staged, as: UTF8.self).contains("a.txt"))
    }
}
