import XCTest
import GitKit
import DiffEngine

/// 性能是本项目的最高优先级，这些测试是它的守卫。
/// 用显式的耗时断言而不是 XCTest 的 measure baseline，因为 baseline
/// 需要人工录制、在 CI 上不可靠，而我们要的是"超了就挂"的硬门禁。
final class LargeRepoPerformanceTests: XCTestCase {
    // XCTest 保证 class setUp 完成后才跑实例测试，tearDown 在全部测试结束后才跑。
    nonisolated(unsafe) private static var repositoryURL: URL!

    override class func setUp() {
        super.setUp()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-perf-fixture")
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PerformanceTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("Scripts/make-large-fixture.sh")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, url.path]
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        repositoryURL = url
    }

    override class func tearDown() {
        if let repositoryURL { try? FileManager.default.removeItem(at: repositoryURL) }
        super.tearDown()
    }

    /// 预算：切换仓库/worktree 到文件列表可见 < 150ms（1000 个改动文件）。
    func testStatusOnThousandChangedFilesUnder150ms() async throws {
        let repository = GitRepository(root: Self.repositoryURL)
        // 预热一次，避免把文件系统冷缓存算进去。
        _ = try await repository.status()

        let start = ContinuousClock.now
        let statuses = try await repository.status()
        let elapsed = ContinuousClock.now - start

        print("PERF status: \(elapsed)")
        XCTAssertGreaterThanOrEqual(statuses.count, 1_000)
        XCTAssertLessThan(elapsed, .milliseconds(150),
                          "status 耗时 \(elapsed)，预算是 150ms")
    }

    /// 预算：点击文件到 diff 可见 < 100ms（2000 行以内的文件）。
    func testSingleFileDiffUnder100ms() async throws {
        let repository = GitRepository(root: Self.repositoryURL)
        let engine = DiffEngine()
        let statuses = try await repository.status()
        let target = try XCTUnwrap(statuses.first { $0.path.hasSuffix(".ts") })
        _ = try await engine.load(status: target, staged: false, from: repository)
        await engine.invalidate(worktreePath: Self.repositoryURL)

        let start = ContinuousClock.now
        _ = try await engine.load(status: target, staged: false, from: repository)
        let elapsed = ContinuousClock.now - start

        print("PERF single-file diff: \(elapsed)")
        XCTAssertLessThan(elapsed, .milliseconds(100),
                          "单文件 diff 耗时 \(elapsed)，预算是 100ms")
    }

    /// 树构建发生在主线程上（它是纯函数且很快），所以必须真的很快。
    func testTreeBuildOnThousandFilesUnder30ms() async throws {
        let repository = GitRepository(root: Self.repositoryURL)
        let statuses = try await repository.status()

        let start = ContinuousClock.now
        let tree = FileTreeBuilder.build(from: statuses, collapsingSingleChildDirectories: true)
        let elapsed = ContinuousClock.now - start

        print("PERF tree build: \(elapsed)")
        XCTAssertFalse(tree.isEmpty)
        XCTAssertLessThan(elapsed, .milliseconds(30),
                          "树构建耗时 \(elapsed)，预算是 30ms")
    }

    /// 大 lockfile 必须走折叠路径，绝不能真的去解析它。
    func testHugeGeneratedFileIsCollapsedInstantly() async throws {
        let repository = GitRepository(root: Self.repositoryURL)
        let engine = DiffEngine()
        let statuses = try await repository.status()
        let lockfile = try XCTUnwrap(statuses.first { $0.path == "pnpm-lock.yaml" })

        let start = ContinuousClock.now
        let loaded = try await engine.load(status: lockfile, staged: false, from: repository)
        let elapsed = ContinuousClock.now - start

        print("PERF collapsed lockfile: \(elapsed)")
        guard case .collapsed = loaded else {
            return XCTFail("50000 行的 lockfile 必须被折叠，实际是 \(loaded)")
        }
        XCTAssertLessThan(elapsed, .milliseconds(10),
                          "折叠判断不应读取文件内容，耗时 \(elapsed)")
    }
}
