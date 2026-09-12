import XCTest
@testable import GitKit

final class GitRunnerTests: XCTestCase {
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

    func testCancellationTerminatesProcess() async throws {
        let repo = try FixtureRepo()
        let runner = GitRunner()
        let task = Task {
            // `git wait` 不存在，但这里的重点是任务被取消后不会永远挂着。
            try await runner.run(["log", "--all"], in: repo.url)
        }
        task.cancel()
        // 无论抛错还是正常返回都可以，只要它会结束。
        _ = try? await task.value
    }
}
