# Sift 核心阅读器 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个原生 macOS 应用，能添加多个 Git 仓库、在侧边栏中按层级展示每个仓库及其 worktree、列出改动文件（平铺或树视图）、并查看单个文件的 diff。

**Architecture:** 全部逻辑放在一个本地 SwiftPM 包中，按单一职责切成六个模块；Xcode 工程只作为应用壳。所有 git 交互通过 shell out 调用 `git` 子进程完成，解析部分为纯函数，对着脚本生成的 fixture 仓库测试。diff 视图使用 AppKit 的 `NSTextView` 包进 SwiftUI，因为 SwiftUI 的文本渲染在超长文档上撑不住。

**Tech Stack:** Swift 6、SwiftPM、SwiftUI（外壳）、AppKit / NSTextView（diff 渲染）、FSEvents（文件变更监听）、XCTest。零第三方依赖。

## Global Constraints

- 最低系统版本：macOS 26。
- 零第三方依赖。所有功能用系统框架或 shell out 到 `git` 实现。
- **主线程上永不调用 git。** 不使用 `process.waitUntilExit()` 作为主要等待手段，不在主线程读管道。
- **永不轮询。** 文件变更只通过 FSEvents 感知，合并抖动窗口 100ms。
- **diff 懒算。** 只有用户点开的文件才计算 diff。
- **切换即取消。** 切换文件、仓库或 worktree 时，旧选区所有在途任务立即取消。
- 性能硬指标（超阈值则构建失败）：冷启动到可交互 < 300ms；切换仓库/worktree 到文件列表可见 < 150ms（1000 个改动文件）；点击文件到 diff 可见 < 100ms（2000 行以内文件）；空闲 CPU 恒定 0%；挂载 5 个仓库时常驻内存 < 150MB。
- 所有操作必须鼠标可达。快捷键只能作为加速手段，不能是某功能的唯一入口。
- 字体只用 SF Pro（界面）与 SF Mono（代码）。配色基于系统语义色，diff 增删色除外（需为浅色与深色模式分别调校）。
- 本计划**不包含**：语法高亮、stage/discard 操作、AI 面板、blame、连续滚动模式。这些属于计划二。

---

## File Structure

```
Sift/
  Package.swift                                SwiftPM 包定义
  Sources/
    GitKit/                                    git 子进程调用与输出解析，不感知 UI
      GitRunner.swift                          异步子进程执行，可取消，带超时
      GitError.swift                           错误类型
      FileStatus.swift                         文件状态模型
      StatusParser.swift                       解析 git status --porcelain=v2 -z
      Worktree.swift                           worktree 模型
      WorktreeParser.swift                     解析 git worktree list --porcelain
      FileDiff.swift                           diff 模型（FileDiff / Hunk / DiffLine）
      DiffParser.swift                         解析统一 diff 格式
      NumstatParser.swift                      解析 git diff --numstat -z，供列表显示 +N −M
      GitRepository.swift                      门面：组合 runner 与 parser
    DiffEngine/                                可渲染模型、缓存、生成文件识别
      GeneratedFileDetector.swift              生成文件与超大文件识别规则
      DiffCache.swift                          LRU 缓存
      DiffEngine.swift                         懒加载入口
      FileTreeBuilder.swift                    扁平路径列表 → 树结构（纯函数）
    RepoStore/                                 应用状态与持久化
      RepoStore.swift                          可观察状态容器
      PersistedState.swift                     磁盘格式与读写
      FileSystemWatcher.swift                  FSEvents 封装，含防抖
    SiftUI/                                    界面
      ContentView.swift                        三栏骨架
      SourceSidebar.swift                      左栏：仓库 + worktree
      FileListPane.swift                       中栏：改动文件
      DiffPane.swift                           右栏：diff 容器与工具栏
      DiffDocumentBuilder.swift                FileDiff → NSAttributedString（纯函数）
      DiffTextView.swift                       NSTextView 的 NSViewRepresentable 封装
      Theme.swift                              颜色与字体
  Tests/
    GitKitTests/
      FixtureRepo.swift                        测试用临时 git 仓库工厂
      GitRunnerTests.swift
      StatusParserTests.swift
      WorktreeParserTests.swift
      DiffParserTests.swift
      GitRepositoryTests.swift
    DiffEngineTests/
      GeneratedFileDetectorTests.swift
      DiffCacheTests.swift
      FileTreeBuilderTests.swift
    RepoStoreTests/
      PersistedStateTests.swift
      FileSystemWatcherTests.swift
    PerformanceTests/
      LargeRepoPerformanceTests.swift
  Scripts/
    make-large-fixture.sh                      生成 1000 个改动文件的大仓库
    preflight.sh                               构建 + 测试 + 性能门禁
  App/
    Sift.xcodeproj                             应用壳
    Sift/
      SiftApp.swift
      Assets.xcassets
```

**边界说明：** `GitKit` 不知道 `DiffEngine` 存在，`DiffEngine` 不知道 `RepoStore` 存在，三者都不知道 `SiftUI` 存在。依赖方向单向向上。`SiftUI` 里所有能抽成纯函数的逻辑（`FileTreeBuilder`、`DiffDocumentBuilder`）都抽出去单独测，SwiftUI 视图本身不写自动化测试。

---

### Task 1: SwiftPM 骨架与 fixture 测试基础设施

**Files:**
- Create: `Package.swift`
- Create: `Tests/GitKitTests/FixtureRepo.swift`
- Create: `Tests/GitKitTests/FixtureRepoTests.swift`
- Create: `Sources/GitKit/GitError.swift`

**Interfaces:**
- Produces: `FixtureRepo` 类，供后续所有 GitKit 测试使用。方法签名：`init() throws`、`@discardableResult func git(_ args: String...) throws -> String`、`func write(_ contents: String, to path: String) throws`、`func delete(_ path: String) throws`、`func commit(_ message: String) throws`、`var url: URL`。
- Produces: `GitError` 枚举，case 为 `.launchFailed(String)`、`.nonZeroExit(command: String, exitCode: Int32, stderr: String)`、`.timedOut(command: String)`。

- [ ] **Step 1: 创建 Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sift",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "GitKit", targets: ["GitKit"]),
        .library(name: "DiffEngine", targets: ["DiffEngine"]),
        .library(name: "RepoStore", targets: ["RepoStore"]),
        .library(name: "SiftUI", targets: ["SiftUI"]),
    ],
    targets: [
        .target(name: "GitKit"),
        .target(name: "DiffEngine", dependencies: ["GitKit"]),
        .target(name: "RepoStore", dependencies: ["GitKit", "DiffEngine"]),
        .target(name: "SiftUI", dependencies: ["GitKit", "DiffEngine", "RepoStore"]),
        .testTarget(name: "GitKitTests", dependencies: ["GitKit"]),
        .testTarget(name: "DiffEngineTests", dependencies: ["DiffEngine"]),
        .testTarget(name: "RepoStoreTests", dependencies: ["RepoStore"]),
        .testTarget(name: "PerformanceTests", dependencies: ["GitKit", "DiffEngine", "RepoStore"]),
    ]
)
```

- [ ] **Step 2: 创建占位源文件让包能编译**

`Sources/GitKit/GitError.swift`：

```swift
import Foundation

public enum GitError: Error, Sendable, Equatable {
    case launchFailed(String)
    case nonZeroExit(command: String, exitCode: Int32, stderr: String)
    case timedOut(command: String)
}
```

其余四个 target 各创建一个空目录占位文件（`Sources/DiffEngine/Placeholder.swift` 等），内容为 `// Intentionally empty until Task N.`。测试 target 同理，各放一个空的 `XCTestCase` 子类，否则 SwiftPM 会因为目录不存在而报错。

- [ ] **Step 3: 验证包结构成立**

Run: `swift build`
Expected: `Build complete!`

如果 `.macOS(.v26)` 报错说该 case 不存在，改为 `.macOS("26.0")` 后重跑。

- [ ] **Step 4: 写 FixtureRepo**

`Tests/GitKitTests/FixtureRepo.swift`：

```swift
import Foundation

/// 在临时目录中创建一次性 git 仓库，供解析器测试使用。
/// 每个实例拥有独立目录，析构时自动清理。
final class FixtureRepo {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git("init", "-b", "main")
        try git("config", "user.email", "test@sift.local")
        try git("config", "user.name", "Sift Test")
        try git("config", "commit.gpgsign", "false")
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func git(_ args: String...) throws -> String {
        try runGit(args)
    }

    @discardableResult
    func runGit(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = url
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw FixtureError.gitFailed(args.joined(separator: " "), output)
        }
        return output
    }

    func write(_ contents: String, to path: String) throws {
        let target = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: target, atomically: true, encoding: .utf8)
    }

    func delete(_ path: String) throws {
        try FileManager.default.removeItem(at: url.appendingPathComponent(path))
    }

    func commit(_ message: String) throws {
        try git("add", "-A")
        try git("commit", "-m", message)
    }

    enum FixtureError: Error {
        case gitFailed(String, String)
    }
}
```

注意：这里用 `waitUntilExit()` 是可以的——这是测试辅助代码，不是产品代码，且 fixture 的 git 输出量很小，不会撑爆管道缓冲。产品代码中的 `GitRunner`（Task 2）不允许这样做。

- [ ] **Step 5: 写 FixtureRepo 的自测**

`Tests/GitKitTests/FixtureRepoTests.swift`：

```swift
import XCTest
@testable import GitKit

final class FixtureRepoTests: XCTestCase {
    func testCreatesRepositoryWithCommit() throws {
        let repo = try FixtureRepo()
        try repo.write("hello\n", to: "a.txt")
        try repo.commit("initial")

        let log = try repo.git("log", "--oneline")
        XCTAssertTrue(log.contains("initial"), "期望日志包含提交信息，实际是：\(log)")
    }

    func testWriteCreatesIntermediateDirectories() throws {
        let repo = try FixtureRepo()
        try repo.write("x\n", to: "deep/nested/dir/file.txt")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repo.url.appendingPathComponent("deep/nested/dir/file.txt").path))
    }

    func testNonZeroExitThrows() throws {
        let repo = try FixtureRepo()
        XCTAssertThrowsError(try repo.git("this-is-not-a-git-command"))
    }
}
```

- [ ] **Step 6: 跑测试**

Run: `swift test --filter FixtureRepoTests`
Expected: 3 个测试全部通过。

- [ ] **Step 7: 提交**

```bash
git add Package.swift Sources Tests
git commit -m "feat: SwiftPM 骨架与 fixture 测试基础设施"
```

---

### Task 2: GitRunner —— 异步子进程执行

**Files:**
- Create: `Sources/GitKit/GitRunner.swift`
- Create: `Tests/GitKitTests/GitRunnerTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `GitError`、`FixtureRepo`。
- Produces: `GitOutput` 结构体（`stdout: Data`、`stderr: String`、`exitCode: Int32`）与 `GitRunner` 结构体，方法为 `func run(_ arguments: [String], in directory: URL) async throws -> Data`（非零退出时抛 `GitError.nonZeroExit`）和 `func runAllowingFailure(_ arguments: [String], in directory: URL) async throws -> GitOutput`（不抛非零退出）。初始化器 `init(timeout: Duration = .seconds(30))`。

- [ ] **Step 1: 写失败的测试**

`Tests/GitKitTests/GitRunnerTests.swift`：

```swift
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter GitRunnerTests`
Expected: 编译失败，报 `cannot find 'GitRunner' in scope`。

- [ ] **Step 3: 实现 GitRunner**

`Sources/GitKit/GitRunner.swift`：

```swift
import Foundation

public struct GitOutput: Sendable {
    public let stdout: Data
    public let stderr: String
    public let exitCode: Int32
}

/// 异步执行 git 子进程。
///
/// 关键设计约束：
/// 1. 两个管道必须与进程退出**并发**读取。如果先 `waitUntilExit()` 再读管道，
///    git 一旦写满 64KB 的管道缓冲区就会阻塞，而我们在等它退出——双方永久死锁。
///    任何真实仓库的 diff 都会超过 64KB，所以这不是边角情况，是常态。
/// 2. 不使用 `waitUntilExit()` 作为主要等待手段。两个管道都读到 EOF 时，
///    git 已经关闭了它的输出，此时再调用 `waitUntilExit()` 会立即返回。
/// 3. 任务取消时终止子进程，不留孤儿。
public struct GitRunner: Sendable {
    private let timeout: Duration
    private static let executable = URL(fileURLWithPath: "/usr/bin/git")

    public init(timeout: Duration = .seconds(30)) {
        self.timeout = timeout
    }

    /// 执行 git，非零退出时抛错。
    public func run(_ arguments: [String], in directory: URL) async throws -> Data {
        let output = try await runAllowingFailure(arguments, in: directory)
        guard output.exitCode == 0 else {
            throw GitError.nonZeroExit(
                command: arguments.joined(separator: " "),
                exitCode: output.exitCode,
                stderr: output.stderr)
        }
        return output.stdout
    }

    /// 执行 git，非零退出也正常返回，由调用方判断。
    public func runAllowingFailure(_ arguments: [String], in directory: URL) async throws -> GitOutput {
        let process = Process()
        process.executableURL = Self.executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        // 禁止 git 弹凭证提示（否则子进程会永远挂着），并避免为只读操作抢 index 锁。
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
        ]) { _, new in new }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw GitError.launchFailed(String(describing: error))
        }

        // 超时守卫：到点直接终止进程，管道随之 EOF，下面的读取自然结束。
        let timeoutTask = Task { [timeout] in
            try await Task.sleep(for: timeout)
            if process.isRunning { process.terminate() }
        }
        defer { timeoutTask.cancel() }

        let output: (Data, Data) = await withTaskCancellationHandler {
            async let out = Self.drain(stdoutPipe)
            async let err = Self.drain(stderrPipe)
            return await (out, err)
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        // 两个管道都已 EOF，进程要么已退出要么正在退出，这里不会实质阻塞。
        process.waitUntilExit()

        if timeoutTask.isCancelled == false, process.terminationReason == .uncaughtSignal {
            throw GitError.timedOut(command: arguments.joined(separator: " "))
        }

        return GitOutput(
            stdout: output.0,
            stderr: String(decoding: output.1, as: UTF8.self),
            exitCode: process.terminationStatus)
    }

    /// 在后台队列上把一个管道读到 EOF。
    private static func drain(_ pipe: Pipe) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: data)
            }
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter GitRunnerTests`
Expected: 5 个测试全部通过。大输出那个测试如果挂住不返回，说明管道读取写错了，回到 Step 3 检查。

- [ ] **Step 5: 提交**

```bash
git add Sources/GitKit/GitRunner.swift Tests/GitKitTests/GitRunnerTests.swift
git commit -m "feat(GitKit): 异步 git 子进程执行器"
```

---

### Task 3: StatusParser —— 解析 porcelain v2

**Files:**
- Create: `Sources/GitKit/FileStatus.swift`
- Create: `Sources/GitKit/StatusParser.swift`
- Create: `Tests/GitKitTests/StatusParserTests.swift`

**Interfaces:**
- Consumes: Task 2 的 `GitRunner`，Task 1 的 `FixtureRepo`。
- Produces: `FileChangeKind` 枚举、`FileStatus` 结构体、`StatusParser.parse(_ data: Data) throws -> [FileStatus]`、`StatusParseError` 枚举。

**背景：** `git status --porcelain=v2 -z --untracked-files=all` 的记录格式：

- 普通改动：`1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>`（空格分隔 9 段，path 是第 9 段且可能含空格）
- 重命名/复制：`2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>` 共 10 段，**其后紧跟一个独立的 NUL 分隔字段存放原路径**
- 未合并：`u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>` 共 11 段
- 未跟踪：`? <path>`
- 已忽略：`! <path>`

最容易写错的一点是类型 2 的记录会消耗**两个** NUL 分隔字段。

XY 状态码：`.` 未改动、`M` 修改、`A` 新增、`D` 删除、`R` 重命名、`C` 复制、`T` 类型变更、`U` 未合并。

- [ ] **Step 1: 写模型**

`Sources/GitKit/FileStatus.swift`：

```swift
import Foundation

public enum FileChangeKind: String, Sendable, Equatable {
    case unmodified
    case modified
    case added
    case deleted
    case renamed
    case copied
    case typeChanged
    case unmerged
    case untracked
}

public struct FileStatus: Sendable, Equatable, Identifiable, Hashable {
    /// 相对仓库根目录的路径。
    public let path: String
    /// 重命名或复制时的原路径，其余情况为 nil。
    public let originalPath: String?
    /// 暂存区一侧的状态（porcelain 的 X 位）。
    public let indexStatus: FileChangeKind
    /// 工作区一侧的状态（porcelain 的 Y 位）。
    public let worktreeStatus: FileChangeKind

    public var id: String { path }

    public init(path: String, originalPath: String?,
                indexStatus: FileChangeKind, worktreeStatus: FileChangeKind) {
        self.path = path
        self.originalPath = originalPath
        self.indexStatus = indexStatus
        self.worktreeStatus = worktreeStatus
    }

    public var isUntracked: Bool { indexStatus == .untracked }
    /// 有已暂存的改动，应出现在 Staged 分组。
    public var hasStagedChanges: Bool {
        !isUntracked && indexStatus != .unmodified
    }
    /// 有未暂存的改动，应出现在 Unstaged 分组。
    public var hasUnstagedChanges: Bool {
        !isUntracked && worktreeStatus != .unmodified
    }
    /// 文件名，用于 UI 显示。
    public var fileName: String {
        String(path.split(separator: "/").last ?? "")
    }
}
```

- [ ] **Step 2: 写失败的测试**

`Tests/GitKitTests/StatusParserTests.swift`：

```swift
import XCTest
@testable import GitKit

final class StatusParserTests: XCTestCase {
    private let runner = GitRunner()
    private let statusArgs = ["status", "--porcelain=v2", "-z", "--untracked-files=all"]

    private func status(of repo: FixtureRepo) async throws -> [FileStatus] {
        let data = try await runner.run(statusArgs, in: repo.url)
        return try StatusParser.parse(data)
    }

    func testCleanRepositoryHasNoEntries() async throws {
        let repo = try FixtureRepo()
        try repo.write("a\n", to: "a.txt")
        try repo.commit("initial")
        let result = try await status(of: repo)
        XCTAssertTrue(result.isEmpty)
    }

    func testUnstagedModification() async throws {
        let repo = try FixtureRepo()
        try repo.write("a\n", to: "a.txt")
        try repo.commit("initial")
        try repo.write("changed\n", to: "a.txt")

        let result = try await status(of: repo)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].path, "a.txt")
        XCTAssertEqual(result[0].indexStatus, .unmodified)
        XCTAssertEqual(result[0].worktreeStatus, .modified)
        XCTAssertTrue(result[0].hasUnstagedChanges)
        XCTAssertFalse(result[0].hasStagedChanges)
    }

    func testStagedAndUnstagedOnSameFile() async throws {
        let repo = try FixtureRepo()
        try repo.write("a\n", to: "a.txt")
        try repo.commit("initial")
        try repo.write("staged\n", to: "a.txt")
        try repo.git("add", "a.txt")
        try repo.write("staged then modified again\n", to: "a.txt")

        let result = try await status(of: repo)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].indexStatus, .modified)
        XCTAssertEqual(result[0].worktreeStatus, .modified)
        XCTAssertTrue(result[0].hasStagedChanges)
        XCTAssertTrue(result[0].hasUnstagedChanges)
    }

    func testUntrackedFile() async throws {
        let repo = try FixtureRepo()
        try repo.write("a\n", to: "a.txt")
        try repo.commit("initial")
        try repo.write("new\n", to: "new.txt")

        let result = try await status(of: repo)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].path, "new.txt")
        XCTAssertTrue(result[0].isUntracked)
    }

    func testDeletedFile() async throws {
        let repo = try FixtureRepo()
        try repo.write("a\n", to: "a.txt")
        try repo.commit("initial")
        try repo.delete("a.txt")

        let result = try await status(of: repo)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].worktreeStatus, .deleted)
    }

    /// 类型 2 的记录会消耗两个 NUL 字段。如果解析器没处理，
    /// 原路径会被当成下一条记录，导致后续全部错位。
    func testRenameRecordConsumesTwoFields() async throws {
        let repo = try FixtureRepo()
        try repo.write(String(repeating: "content line\n", count: 20), to: "old.txt")
        try repo.write("other\n", to: "zzz.txt")
        try repo.commit("initial")
        try repo.git("mv", "old.txt", "new.txt")
        try repo.write("other changed\n", to: "zzz.txt")

        let result = try await status(of: repo)
        let renamed = try XCTUnwrap(result.first { $0.indexStatus == .renamed })
        XCTAssertEqual(renamed.path, "new.txt")
        XCTAssertEqual(renamed.originalPath, "old.txt")
        // 关键断言：重命名之后的记录没有被吞掉或错位。
        XCTAssertTrue(result.contains { $0.path == "zzz.txt" },
                      "重命名记录后面的文件丢失了，说明多消耗或少消耗了字段：\(result)")
    }

    func testPathWithSpaces() async throws {
        let repo = try FixtureRepo()
        try repo.write("a\n", to: "dir with spaces/file name.txt")
        try repo.commit("initial")
        try repo.write("changed\n", to: "dir with spaces/file name.txt")

        let result = try await status(of: repo)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].path, "dir with spaces/file name.txt")
    }

    func testPathWithQuotesAndUnicode() async throws {
        let repo = try FixtureRepo()
        let tricky = "中文目录/it's \"quoted\".txt"
        try repo.write("a\n", to: tricky)
        try repo.commit("initial")
        try repo.write("changed\n", to: tricky)

        let result = try await status(of: repo)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].path, tricky,
                       "-z 模式下路径不应被转义，实际得到：\(result[0].path)")
    }

    func testMultipleFilesAllParsed() async throws {
        let repo = try FixtureRepo()
        for index in 0..<10 { try repo.write("v1\n", to: "f\(index).txt") }
        try repo.commit("initial")
        for index in 0..<10 { try repo.write("v2\n", to: "f\(index).txt") }

        let result = try await status(of: repo)
        XCTAssertEqual(result.count, 10)
    }
}
```

- [ ] **Step 3: 跑测试确认失败**

Run: `swift test --filter StatusParserTests`
Expected: 编译失败，报 `cannot find 'StatusParser' in scope`。

- [ ] **Step 4: 实现解析器**

`Sources/GitKit/StatusParser.swift`：

```swift
import Foundation

public enum StatusParseError: Error, Sendable, Equatable {
    case malformedRecord(String)
    case truncatedRenameRecord(String)
    case unknownStatusCode(Character)
}

/// 解析 `git status --porcelain=v2 -z --untracked-files=all` 的输出。
///
/// 记录以 NUL 分隔。类型 2（重命名/复制）的记录之后紧跟一个**额外的** NUL
/// 分隔字段存放原路径——这是本解析器最容易出错的地方。
public enum StatusParser {
    public static func parse(_ data: Data) throws -> [FileStatus] {
        let fields = data
            .split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }

        var result: [FileStatus] = []
        var index = 0

        while index < fields.count {
            let field = fields[index]
            index += 1
            guard let marker = field.first else { continue }

            switch marker {
            case "1":
                result.append(try parseOrdinary(field))
            case "2":
                guard index < fields.count else {
                    throw StatusParseError.truncatedRenameRecord(field)
                }
                let originalPath = fields[index]
                index += 1
                result.append(try parseRename(field, originalPath: originalPath))
            case "u":
                result.append(try parseUnmerged(field))
            case "?":
                result.append(FileStatus(
                    path: String(field.dropFirst(2)),
                    originalPath: nil,
                    indexStatus: .untracked,
                    worktreeStatus: .untracked))
            default:
                // `#` 开头的头部行、`!` 开头的忽略项，以及任何未来新增的记录类型，
                // 都安全跳过而不是报错——宁可少显示一个文件，也不要整个列表炸掉。
                continue
            }
        }
        return result
    }

    /// `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>` —— 9 段，path 可能含空格。
    private static func parseOrdinary(_ field: String) throws -> FileStatus {
        let parts = field.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
        guard parts.count == 9 else { throw StatusParseError.malformedRecord(field) }
        let (index, worktree) = try statusPair(parts[1], in: field)
        return FileStatus(path: String(parts[8]), originalPath: nil,
                          indexStatus: index, worktreeStatus: worktree)
    }

    /// `2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>` —— 10 段。
    private static func parseRename(_ field: String, originalPath: String) throws -> FileStatus {
        let parts = field.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
        guard parts.count == 10 else { throw StatusParseError.malformedRecord(field) }
        let (index, worktree) = try statusPair(parts[1], in: field)
        return FileStatus(path: String(parts[9]), originalPath: originalPath,
                          indexStatus: index, worktreeStatus: worktree)
    }

    /// `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>` —— 11 段。
    private static func parseUnmerged(_ field: String) throws -> FileStatus {
        let parts = field.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
        guard parts.count == 11 else { throw StatusParseError.malformedRecord(field) }
        return FileStatus(path: String(parts[10]), originalPath: nil,
                          indexStatus: .unmerged, worktreeStatus: .unmerged)
    }

    private static func statusPair(
        _ xy: Substring, in record: String
    ) throws -> (FileChangeKind, FileChangeKind) {
        let characters = Array(xy)
        guard characters.count == 2 else { throw StatusParseError.malformedRecord(record) }
        return (try kind(from: characters[0]), try kind(from: characters[1]))
    }

    private static func kind(from character: Character) throws -> FileChangeKind {
        switch character {
        case ".": return .unmodified
        case "M": return .modified
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "T": return .typeChanged
        case "U": return .unmerged
        default: throw StatusParseError.unknownStatusCode(character)
        }
    }
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `swift test --filter StatusParserTests`
Expected: 9 个测试全部通过。

- [ ] **Step 6: 提交**

```bash
git add Sources/GitKit/FileStatus.swift Sources/GitKit/StatusParser.swift Tests/GitKitTests/StatusParserTests.swift
git commit -m "feat(GitKit): porcelain v2 状态解析"
```

---

### Task 4: WorktreeParser —— 发现 worktree

**Files:**
- Create: `Sources/GitKit/Worktree.swift`
- Create: `Sources/GitKit/WorktreeParser.swift`
- Create: `Tests/GitKitTests/WorktreeParserTests.swift`

**Interfaces:**
- Consumes: Task 2 的 `GitRunner`，Task 1 的 `FixtureRepo`。
- Produces: `Worktree` 结构体与 `WorktreeParser.parse(_ data: Data) -> [Worktree]`。

**背景：** `git worktree list --porcelain` 输出以空行分隔的记录块，第一块永远是主工作树：

```
worktree /path/to/main
HEAD 0123456789abcdef0123456789abcdef01234567
branch refs/heads/main

worktree /path/to/feature-wt
HEAD fedcba9876543210fedcba9876543210fedcba98
detached
```

可能出现的额外行：`bare`、`locked`、`prunable`。

- [ ] **Step 1: 写模型**

`Sources/GitKit/Worktree.swift`：

```swift
import Foundation

public struct Worktree: Sendable, Equatable, Identifiable, Hashable {
    public let path: URL
    /// 完整的 commit SHA，裸仓库为 nil。
    public let head: String?
    /// 短分支名（已去掉 refs/heads/ 前缀）。游离头指针或裸仓库为 nil。
    public let branch: String?
    public let isBare: Bool
    public let isDetached: Bool
    public let isLocked: Bool
    /// `git worktree list` 输出的第一条永远是主工作树。
    public let isMain: Bool

    public var id: URL { path }

    public init(path: URL, head: String?, branch: String?,
                isBare: Bool, isDetached: Bool, isLocked: Bool, isMain: Bool) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isBare = isBare
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.isMain = isMain
    }

    /// 侧边栏中显示的名字：优先分支名，其次短 SHA，最后目录名。
    public var displayName: String {
        if let branch { return branch }
        if let head { return String(head.prefix(7)) }
        return path.lastPathComponent
    }
}
```

- [ ] **Step 2: 写失败的测试**

`Tests/GitKitTests/WorktreeParserTests.swift`：

```swift
import XCTest
@testable import GitKit

final class WorktreeParserTests: XCTestCase {
    private let runner = GitRunner()

    private func worktrees(of repo: FixtureRepo) async throws -> [Worktree] {
        let data = try await runner.run(["worktree", "list", "--porcelain"], in: repo.url)
        return WorktreeParser.parse(data)
    }

    func testSingleRepositoryReportsOneMainWorktree() async throws {
        let repo = try FixtureRepo()
        try repo.write("a\n", to: "a.txt")
        try repo.commit("initial")

        let result = try await worktrees(of: repo)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].isMain)
        XCTAssertEqual(result[0].branch, "main")
        XCTAssertFalse(result[0].isDetached)
        XCTAssertFalse(result[0].isBare)
    }

    func testAdditionalWorktreeIsDiscovered() async throws {
        let repo = try FixtureRepo()
        try repo.write("a\n", to: "a.txt")
        try repo.commit("initial")

        let extra = repo.url.deletingLastPathComponent()
            .appendingPathComponent("wt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: extra) }
        try repo.git("worktree", "add", "-b", "feature", extra.path)

        let result = try await worktrees(of: repo)
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0].isMain, "第一条必须是主工作树")
        XCTAssertFalse(result[1].isMain)
        XCTAssertEqual(result[1].branch, "feature")
    }

    func testDetachedWorktree() async throws {
        let repo = try FixtureRepo()
        try repo.write("a\n", to: "a.txt")
        try repo.commit("initial")
        let sha = try repo.git("rev-parse", "HEAD")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let extra = repo.url.deletingLastPathComponent()
            .appendingPathComponent("wt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: extra) }
        try repo.git("worktree", "add", "--detach", extra.path, sha)

        let result = try await worktrees(of: repo)
        let detached = try XCTUnwrap(result.first { !$0.isMain })
        XCTAssertTrue(detached.isDetached)
        XCTAssertNil(detached.branch)
        XCTAssertEqual(detached.head, sha)
        XCTAssertEqual(detached.displayName, String(sha.prefix(7)))
    }

    func testParsesBareAndLockedFlagsFromRawOutput() {
        let raw = """
        worktree /repos/main
        HEAD 0123456789abcdef0123456789abcdef01234567
        branch refs/heads/main

        worktree /repos/locked-wt
        HEAD fedcba9876543210fedcba9876543210fedcba98
        detached
        locked

        worktree /repos/bare
        bare

        """
        let result = WorktreeParser.parse(Data(raw.utf8))
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].branch, "main")
        XCTAssertTrue(result[1].isLocked)
        XCTAssertTrue(result[1].isDetached)
        XCTAssertTrue(result[2].isBare)
        XCTAssertNil(result[2].head)
    }
}
```

- [ ] **Step 3: 跑测试确认失败**

Run: `swift test --filter WorktreeParserTests`
Expected: 编译失败，报 `cannot find 'WorktreeParser' in scope`。

- [ ] **Step 4: 实现解析器**

`Sources/GitKit/WorktreeParser.swift`：

```swift
import Foundation

/// 解析 `git worktree list --porcelain` 的输出。
/// 记录块以空行分隔，第一块永远是主工作树。
public enum WorktreeParser {
    public static func parse(_ data: Data) -> [Worktree] {
        let text = String(decoding: data, as: UTF8.self)
        let blocks = text
            .components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        return blocks.enumerated().compactMap { offset, block in
            parseBlock(block, isMain: offset == 0)
        }
    }

    private static func parseBlock(_ block: String, isMain: Bool) -> Worktree? {
        var path: URL?
        var head: String?
        var branch: String?
        var isBare = false
        var isDetached = false
        var isLocked = false

        for line in block.split(separator: "\n", omittingEmptySubsequences: true) {
            if let value = value(of: "worktree", in: line) {
                path = URL(fileURLWithPath: value)
            } else if let value = value(of: "HEAD", in: line) {
                head = value
            } else if let value = value(of: "branch", in: line) {
                // 形如 refs/heads/feature，只保留短名。
                branch = value.hasPrefix("refs/heads/")
                    ? String(value.dropFirst("refs/heads/".count))
                    : value
            } else if line == "bare" {
                isBare = true
            } else if line == "detached" {
                isDetached = true
            } else if line == "locked" || line.hasPrefix("locked ") {
                isLocked = true
            }
        }

        guard let path else { return nil }
        return Worktree(path: path, head: head, branch: branch,
                        isBare: isBare, isDetached: isDetached,
                        isLocked: isLocked, isMain: isMain)
    }

    private static func value(of key: String, in line: Substring) -> String? {
        let prefix = key + " "
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `swift test --filter WorktreeParserTests`
Expected: 4 个测试全部通过。

- [ ] **Step 6: 提交**

```bash
git add Sources/GitKit/Worktree.swift Sources/GitKit/WorktreeParser.swift Tests/GitKitTests/WorktreeParserTests.swift
git commit -m "feat(GitKit): worktree 发现与解析"
```

---

### Task 5: DiffParser —— 解析统一 diff

**Files:**
- Create: `Sources/GitKit/FileDiff.swift`
- Create: `Sources/GitKit/DiffParser.swift`
- Create: `Tests/GitKitTests/DiffParserTests.swift`

**Interfaces:**
- Consumes: Task 2 的 `GitRunner`，Task 1 的 `FixtureRepo`。
- Produces: `DiffLineKind`、`DiffLine`、`Hunk`、`DiffContent`、`FileDiff`、`DiffParser.parse(_ data: Data, path: String) -> FileDiff`。

- [ ] **Step 1: 写模型**

`Sources/GitKit/FileDiff.swift`：

```swift
import Foundation

public enum DiffLineKind: Sendable, Equatable {
    case context
    case addition
    case deletion
    /// `\ No newline at end of file`
    case noNewlineMarker
}

public struct DiffLine: Sendable, Equatable {
    public let kind: DiffLineKind
    /// 旧文件中的行号，新增行为 nil。
    public let oldLineNumber: Int?
    /// 新文件中的行号，删除行为 nil。
    public let newLineNumber: Int?
    /// 行内容，已去掉行首的 `+` / `-` / 空格标记。
    public let text: String

    public init(kind: DiffLineKind, oldLineNumber: Int?, newLineNumber: Int?, text: String) {
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.text = text
    }
}

public struct Hunk: Sendable, Equatable, Identifiable {
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    /// `@@ ... @@` 之后的内容，git 通常填所属函数签名。
    public let sectionHeading: String
    public let lines: [DiffLine]

    public var id: String { "\(oldStart),\(oldCount),\(newStart),\(newCount)" }

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int,
                sectionHeading: String, lines: [DiffLine]) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.sectionHeading = sectionHeading
        self.lines = lines
    }

    /// 还原成可以喂给 `git apply` 的 hunk 文本。计划二的 stage/discard 会用到。
    public var patchText: String {
        var text = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
        if !sectionHeading.isEmpty { text += " \(sectionHeading)" }
        text += "\n"
        for line in lines {
            switch line.kind {
            case .context: text += " \(line.text)\n"
            case .addition: text += "+\(line.text)\n"
            case .deletion: text += "-\(line.text)\n"
            case .noNewlineMarker: text += "\\ No newline at end of file\n"
            }
        }
        return text
    }
}

public enum DiffContent: Sendable, Equatable {
    case textual([Hunk])
    case binary
    case modeChangeOnly(oldMode: String, newMode: String)
    /// git 没有输出任何差异。
    case empty
}

public struct FileDiff: Sendable, Equatable {
    public let path: String
    public let originalPath: String?
    public let content: DiffContent

    public init(path: String, originalPath: String?, content: DiffContent) {
        self.path = path
        self.originalPath = originalPath
        self.content = content
    }

    public var hunks: [Hunk] {
        if case .textual(let hunks) = content { return hunks }
        return []
    }

    public var addedLineCount: Int {
        hunks.reduce(0) { $0 + $1.lines.count(where: { $0.kind == .addition }) }
    }

    public var deletedLineCount: Int {
        hunks.reduce(0) { $0 + $1.lines.count(where: { $0.kind == .deletion }) }
    }
}
```

- [ ] **Step 2: 写失败的测试**

`Tests/GitKitTests/DiffParserTests.swift`：

```swift
import XCTest
@testable import GitKit

final class DiffParserTests: XCTestCase {
    private let runner = GitRunner()

    private func diff(_ repo: FixtureRepo, path: String, staged: Bool = false) async throws -> FileDiff {
        var args = ["diff", "--no-color", "-U3"]
        if staged { args.append("--cached") }
        args += ["--", path]
        let data = try await runner.run(args, in: repo.url)
        return DiffParser.parse(data, path: path)
    }

    func testSimpleModification() async throws {
        let repo = try FixtureRepo()
        try repo.write("line1\nline2\nline3\n", to: "a.txt")
        try repo.commit("initial")
        try repo.write("line1\nCHANGED\nline3\n", to: "a.txt")

        let result = try await diff(repo, path: "a.txt")
        XCTAssertEqual(result.path, "a.txt")
        XCTAssertEqual(result.hunks.count, 1)
        XCTAssertEqual(result.addedLineCount, 1)
        XCTAssertEqual(result.deletedLineCount, 1)

        let hunk = result.hunks[0]
        XCTAssertEqual(hunk.oldStart, 1)
        XCTAssertEqual(hunk.newStart, 1)
        let added = try XCTUnwrap(hunk.lines.first { $0.kind == .addition })
        XCTAssertEqual(added.text, "CHANGED")
        XCTAssertEqual(added.newLineNumber, 2)
        XCTAssertNil(added.oldLineNumber)
    }

    func testLineNumbersAreCorrectAcrossHunk() async throws {
        let repo = try FixtureRepo()
        let original = (1...20).map { "line\($0)" }.joined(separator: "\n") + "\n"
        try repo.write(original, to: "a.txt")
        try repo.commit("initial")
        var lines = (1...20).map { "line\($0)" }
        lines[9] = "MODIFIED"
        try repo.write(lines.joined(separator: "\n") + "\n", to: "a.txt")

        let result = try await diff(repo, path: "a.txt")
        let hunk = try XCTUnwrap(result.hunks.first)
        let modified = try XCTUnwrap(hunk.lines.first { $0.kind == .addition })
        XCTAssertEqual(modified.newLineNumber, 10)
        let context = try XCTUnwrap(hunk.lines.first { $0.kind == .context })
        XCTAssertEqual(context.oldLineNumber, context.newLineNumber,
                       "本例中上下文行前后行号应一致")
    }

    func testMultipleHunks() async throws {
        let repo = try FixtureRepo()
        let original = (1...60).map { "line\($0)" }.joined(separator: "\n") + "\n"
        try repo.write(original, to: "a.txt")
        try repo.commit("initial")
        var lines = (1...60).map { "line\($0)" }
        lines[2] = "FIRST CHANGE"
        lines[50] = "SECOND CHANGE"
        try repo.write(lines.joined(separator: "\n") + "\n", to: "a.txt")

        let result = try await diff(repo, path: "a.txt")
        XCTAssertEqual(result.hunks.count, 2)
    }

    func testStagedDiff() async throws {
        let repo = try FixtureRepo()
        try repo.write("line1\n", to: "a.txt")
        try repo.commit("initial")
        try repo.write("staged change\n", to: "a.txt")
        try repo.git("add", "a.txt")

        let result = try await diff(repo, path: "a.txt", staged: true)
        XCTAssertEqual(result.addedLineCount, 1)
    }

    func testBinaryFile() async throws {
        let repo = try FixtureRepo()
        try repo.write("placeholder\n", to: "img.bin")
        try repo.commit("initial")
        let binary = Data((0..<512).map { UInt8($0 % 256) })
        try binary.write(to: repo.url.appendingPathComponent("img.bin"))

        let result = try await diff(repo, path: "img.bin")
        XCTAssertEqual(result.content, .binary)
    }

    func testNoNewlineAtEndOfFile() async throws {
        let repo = try FixtureRepo()
        try repo.write("line1\n", to: "a.txt")
        try repo.commit("initial")
        try repo.write("line1\nno trailing newline", to: "a.txt")

        let result = try await diff(repo, path: "a.txt")
        let hunk = try XCTUnwrap(result.hunks.first)
        XCTAssertTrue(hunk.lines.contains { $0.kind == .noNewlineMarker },
                      "应识别出 \\ No newline at end of file 标记")
    }

    func testEmptyDiffWhenNoChanges() async throws {
        let repo = try FixtureRepo()
        try repo.write("line1\n", to: "a.txt")
        try repo.commit("initial")

        let result = try await diff(repo, path: "a.txt")
        XCTAssertEqual(result.content, .empty)
    }

    func testLinesStartingWithPlusOrMinusInContent() async throws {
        let repo = try FixtureRepo()
        try repo.write("normal\n", to: "a.txt")
        try repo.commit("initial")
        // 内容本身以 + 和 - 开头，解析时必须靠位置而非内容判断。
        try repo.write("normal\n+++ not a header\n--- also not\n", to: "a.txt")

        let result = try await diff(repo, path: "a.txt")
        let added = result.hunks.flatMap(\.lines).filter { $0.kind == .addition }
        XCTAssertEqual(added.count, 2)
        XCTAssertEqual(added[0].text, "++ not a header")
        XCTAssertEqual(added[1].text, "-- also not")
    }

    func testPatchTextRoundTripsThroughGitApply() async throws {
        let repo = try FixtureRepo()
        try repo.write("line1\nline2\nline3\n", to: "a.txt")
        try repo.commit("initial")
        try repo.write("line1\nCHANGED\nline3\n", to: "a.txt")

        let result = try await diff(repo, path: "a.txt")
        let hunk = try XCTUnwrap(result.hunks.first)
        // 构造一个完整 patch 并用 --check 验证 git 认可它的格式。
        // 计划二的 hunk 级 stage/discard 完全依赖这一点。
        let patch = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        \(hunk.patchText)
        """
        let patchURL = repo.url.appendingPathComponent("test.patch")
        try patch.write(to: patchURL, atomically: true, encoding: .utf8)
        try repo.git("checkout", "--", "a.txt")
        try repo.git("apply", "--check", "test.patch")
    }
}
```

- [ ] **Step 3: 跑测试确认失败**

Run: `swift test --filter DiffParserTests`
Expected: 编译失败，报 `cannot find 'DiffParser' in scope`。

- [ ] **Step 4: 实现解析器**

`Sources/GitKit/DiffParser.swift`：

```swift
import Foundation

/// 解析 `git diff --no-color -U<n> -- <path>` 针对单个文件的输出。
///
/// 关键点：行的类型必须由**行首第一个字符的位置**决定，不能靠内容猜。
/// 文件内容本身完全可能以 `+++` 或 `---` 开头。
public enum DiffParser {
    private static let hunkHeaderPattern =
        /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@ ?(.*)$/

    public static func parse(_ data: Data, path: String) -> FileDiff {
        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else {
            return FileDiff(path: path, originalPath: nil, content: .empty)
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        var originalPath: String?
        var oldMode: String?
        var newMode: String?
        var hunks: [Hunk] = []
        var isBinary = false

        // 当前正在累积的 hunk
        var currentHeader: (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, heading: String)?
        var currentLines: [DiffLine] = []
        var oldLineNumber = 0
        var newLineNumber = 0

        func flushCurrentHunk() {
            guard let header = currentHeader else { return }
            hunks.append(Hunk(
                oldStart: header.oldStart, oldCount: header.oldCount,
                newStart: header.newStart, newCount: header.newCount,
                sectionHeading: header.heading, lines: currentLines))
            currentHeader = nil
            currentLines = []
        }

        for line in lines {
            // hunk 头
            if line.hasPrefix("@@"),
               let match = try? hunkHeaderPattern.wholeMatch(in: String(line)) {
                flushCurrentHunk()
                let oldStart = Int(match.1) ?? 0
                let oldCount = match.2.flatMap { Int($0) } ?? 1
                let newStart = Int(match.3) ?? 0
                let newCount = match.4.flatMap { Int($0) } ?? 1
                currentHeader = (oldStart, oldCount, newStart, newCount, String(match.5))
                oldLineNumber = oldStart
                newLineNumber = newStart
                continue
            }

            // 尚未进入任何 hunk：解析文件头
            if currentHeader == nil {
                if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                    isBinary = true
                } else if line.hasPrefix("rename from ") {
                    originalPath = String(line.dropFirst("rename from ".count))
                } else if line.hasPrefix("old mode ") {
                    oldMode = String(line.dropFirst("old mode ".count))
                } else if line.hasPrefix("new mode ") {
                    newMode = String(line.dropFirst("new mode ".count))
                }
                continue
            }

            // hunk 内部：靠首字符判断类型
            guard let marker = line.first else {
                // diff 中的空行代表一个空的上下文行。
                currentLines.append(DiffLine(kind: .context,
                                             oldLineNumber: oldLineNumber,
                                             newLineNumber: newLineNumber,
                                             text: ""))
                oldLineNumber += 1
                newLineNumber += 1
                continue
            }

            let body = String(line.dropFirst())
            switch marker {
            case "+":
                currentLines.append(DiffLine(kind: .addition,
                                             oldLineNumber: nil,
                                             newLineNumber: newLineNumber,
                                             text: body))
                newLineNumber += 1
            case "-":
                currentLines.append(DiffLine(kind: .deletion,
                                             oldLineNumber: oldLineNumber,
                                             newLineNumber: nil,
                                             text: body))
                oldLineNumber += 1
            case " ":
                currentLines.append(DiffLine(kind: .context,
                                             oldLineNumber: oldLineNumber,
                                             newLineNumber: newLineNumber,
                                             text: body))
                oldLineNumber += 1
                newLineNumber += 1
            case "\\":
                currentLines.append(DiffLine(kind: .noNewlineMarker,
                                             oldLineNumber: nil,
                                             newLineNumber: nil,
                                             text: body.trimmingCharacters(in: .whitespaces)))
            default:
                // 下一个文件的 `diff --git` 头，或尾部噪音。单文件 diff 中不应出现。
                flushCurrentHunk()
            }
        }
        flushCurrentHunk()

        if isBinary {
            return FileDiff(path: path, originalPath: originalPath, content: .binary)
        }
        if hunks.isEmpty, let oldMode, let newMode {
            return FileDiff(path: path, originalPath: originalPath,
                            content: .modeChangeOnly(oldMode: oldMode, newMode: newMode))
        }
        if hunks.isEmpty {
            return FileDiff(path: path, originalPath: originalPath, content: .empty)
        }
        return FileDiff(path: path, originalPath: originalPath, content: .textual(hunks))
    }
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `swift test --filter DiffParserTests`
Expected: 9 个测试全部通过。

- [ ] **Step 6: 提交**

```bash
git add Sources/GitKit/FileDiff.swift Sources/GitKit/DiffParser.swift Tests/GitKitTests/DiffParserTests.swift
git commit -m "feat(GitKit): 统一 diff 解析"
```

---

### Task 6: GitRepository —— 对外门面

**Files:**
- Create: `Sources/GitKit/NumstatParser.swift`
- Create: `Sources/GitKit/GitRepository.swift`
- Create: `Tests/GitKitTests/GitRepositoryTests.swift`
- Delete: `Sources/GitKit/Placeholder.swift`（如果 Task 1 创建了）

**Interfaces:**
- Consumes: Task 2–5 的 `GitRunner`、`StatusParser`、`WorktreeParser`、`DiffParser`。
- Produces: `LineStats` 结构体（`added: Int`、`deleted: Int`、`isBinary: Bool`）、`NumstatParser.parse(_ data: Data) -> [String: LineStats]`（键为文件路径）。
- Produces: `GitRepository` 结构体。`init(root: URL, runner: GitRunner = GitRunner())`；方法 `func status() async throws -> [FileStatus]`、`func worktrees() async throws -> [Worktree]`、`func diff(path: String, staged: Bool) async throws -> FileDiff`、`func fileContents(path: String) async throws -> String`、`func lineStats() async throws -> [String: LineStats]`；静态方法 `static func discoverRoot(at url: URL, runner: GitRunner) async throws -> URL`。

- [ ] **Step 1: 写失败的测试**

`Tests/GitKitTests/GitRepositoryTests.swift`：

```swift
import XCTest
@testable import GitKit

final class GitRepositoryTests: XCTestCase {
    func testStatusAndDiffTogether() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("line1\nline2\n", to: "a.txt")
        try fixture.commit("initial")
        try fixture.write("line1\nCHANGED\n", to: "a.txt")

        let repo = GitRepository(root: fixture.url)
        let status = try await repo.status()
        XCTAssertEqual(status.count, 1)

        let diff = try await repo.diff(path: status[0].path, staged: false)
        XCTAssertEqual(diff.addedLineCount, 1)
    }

    func testWorktreesIncludesMain() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("a\n", to: "a.txt")
        try fixture.commit("initial")

        let repo = GitRepository(root: fixture.url)
        let worktrees = try await repo.worktrees()
        XCTAssertEqual(worktrees.count, 1)
        XCTAssertTrue(worktrees[0].isMain)
    }

    func testUntrackedFileContentsAreReadFromDisk() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("a\n", to: "a.txt")
        try fixture.commit("initial")
        try fixture.write("brand new\nsecond line\n", to: "new.txt")

        let repo = GitRepository(root: fixture.url)
        let contents = try await repo.fileContents(path: "new.txt")
        XCTAssertEqual(contents, "brand new\nsecond line\n")
    }

    func testDiscoverRootFromSubdirectory() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("a\n", to: "nested/deep/a.txt")
        try fixture.commit("initial")

        let subdirectory = fixture.url.appendingPathComponent("nested/deep")
        let root = try await GitRepository.discoverRoot(at: subdirectory, runner: GitRunner())
        // 临时目录路径可能带 /private 前缀，比较解析后的真实路径。
        XCTAssertEqual(root.resolvingSymlinksInPath().path,
                       fixture.url.resolvingSymlinksInPath().path)
    }

    func testDiscoverRootThrowsOutsideRepository() async throws {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("not-a-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        do {
            _ = try await GitRepository.discoverRoot(at: temporary, runner: GitRunner())
            XCTFail("期望在非 git 目录中抛错")
        } catch {
            // 符合预期
        }
    }

    // MARK: - 行数统计

    func testLineStatsCountsAdditionsAndDeletions() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("a\nb\nc\n", to: "a.txt")
        try fixture.commit("initial")
        try fixture.write("a\nB CHANGED\nc\nd\ne\n", to: "a.txt")

        let stats = try await GitRepository(root: fixture.url).lineStats()
        let entry = try XCTUnwrap(stats["a.txt"])
        XCTAssertEqual(entry.added, 3)
        XCTAssertEqual(entry.deleted, 1)
    }

    func testLineStatsMergesStagedAndUnstaged() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("a\n", to: "staged.txt")
        try fixture.write("a\n", to: "unstaged.txt")
        try fixture.commit("initial")
        try fixture.write("a\nstaged addition\n", to: "staged.txt")
        try fixture.git("add", "staged.txt")
        try fixture.write("a\nunstaged addition\n", to: "unstaged.txt")

        let stats = try await GitRepository(root: fixture.url).lineStats()
        XCTAssertEqual(stats["staged.txt"]?.added, 1, "已暂存的改动也要计入")
        XCTAssertEqual(stats["unstaged.txt"]?.added, 1)
    }

    func testLineStatsMarksBinaryFiles() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("placeholder\n", to: "img.bin")
        try fixture.commit("initial")
        try Data((0..<512).map { UInt8($0 % 256) })
            .write(to: fixture.url.appendingPathComponent("img.bin"))

        let stats = try await GitRepository(root: fixture.url).lineStats()
        XCTAssertTrue(stats["img.bin"]?.isBinary ?? false)
    }

    /// -z 模式下重命名记录的路径字段为空，后面跟两个独立的 NUL 字段。
    /// 和 StatusParser 一样，这是最容易导致后续记录错位的地方。
    func testLineStatsHandlesRenameRecords() async throws {
        let fixture = try FixtureRepo()
        try fixture.write(String(repeating: "content\n", count: 20), to: "old.txt")
        try fixture.write("other\n", to: "zzz.txt")
        try fixture.commit("initial")
        try fixture.git("mv", "old.txt", "new.txt")
        try fixture.write("other changed\n", to: "zzz.txt")

        let stats = try await GitRepository(root: fixture.url).lineStats()
        XCTAssertNotNil(stats["new.txt"], "重命名后的新路径应有统计")
        XCTAssertNotNil(stats["zzz.txt"], "重命名记录之后的文件不应被吞掉")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter GitRepositoryTests`
Expected: 编译失败，报 `cannot find 'GitRepository' in scope`。

- [ ] **Step 3: 实现 numstat 解析器**

`Sources/GitKit/NumstatParser.swift`：

```swift
import Foundation

public struct LineStats: Sendable, Equatable {
    public let added: Int
    public let deleted: Int
    public let isBinary: Bool

    public init(added: Int, deleted: Int, isBinary: Bool) {
        self.added = added
        self.deleted = deleted
        self.isBinary = isBinary
    }

    public func merging(_ other: LineStats) -> LineStats {
        LineStats(added: added + other.added,
                  deleted: deleted + other.deleted,
                  isBinary: isBinary || other.isBinary)
    }
}

/// 解析 `git diff --numstat -z` 的输出。
///
/// 普通记录：`<added>\t<deleted>\t<path>\0`
/// 重命名记录：`<added>\t<deleted>\t\0<oldPath>\0<newPath>\0`
///   —— 路径字段为空，随后是两个**独立的** NUL 字段。没处理这一点的话，
///   重命名之后的所有记录都会错位。
/// 二进制文件的 added / deleted 是 `-`。
public enum NumstatParser {
    public static func parse(_ data: Data) -> [String: LineStats] {
        let fields = data
            .split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }

        var result: [String: LineStats] = [:]
        var index = 0

        while index < fields.count {
            let field = fields[index]
            index += 1
            guard !field.isEmpty else { continue }

            let parts = field.split(separator: "\t", maxSplits: 2,
                                    omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }

            let isBinary = parts[0] == "-"
            let added = Int(parts[0]) ?? 0
            let deleted = Int(parts[1]) ?? 0

            let path: String
            if parts[2].isEmpty {
                // 重命名：跳过旧路径，取新路径。
                guard index + 1 < fields.count else { break }
                index += 1                       // 旧路径
                path = fields[index]             // 新路径
                index += 1
            } else {
                path = String(parts[2])
            }

            let stats = LineStats(added: added, deleted: deleted, isBinary: isBinary)
            result[path] = result[path]?.merging(stats) ?? stats
        }
        return result
    }
}
```

- [ ] **Step 4: 实现门面**

`Sources/GitKit/GitRepository.swift`：

```swift
import Foundation

/// 单个工作树的 git 操作入口。组合 GitRunner 与各解析器，
/// 对上层屏蔽命令行参数细节。
public struct GitRepository: Sendable {
    /// 工作树根目录。对 worktree 而言是该 worktree 自己的目录，不是主仓库目录。
    public let root: URL
    private let runner: GitRunner

    public init(root: URL, runner: GitRunner = GitRunner()) {
        self.root = root
        self.runner = runner
    }

    public func status() async throws -> [FileStatus] {
        let data = try await runner.run(
            ["status", "--porcelain=v2", "-z", "--untracked-files=all"], in: root)
        return try StatusParser.parse(data)
    }

    public func worktrees() async throws -> [Worktree] {
        let data = try await runner.run(["worktree", "list", "--porcelain"], in: root)
        return WorktreeParser.parse(data)
    }

    /// 单个文件的 diff。`staged` 为 true 时对比暂存区与 HEAD，否则对比工作区与暂存区。
    public func diff(path: String, staged: Bool) async throws -> FileDiff {
        var arguments = ["diff", "--no-color", "-U3"]
        if staged { arguments.append("--cached") }
        arguments += ["--", path]
        let data = try await runner.run(arguments, in: root)
        return DiffParser.parse(data, path: path)
    }

    /// 直接从磁盘读文件内容。未跟踪文件没有 diff，需要按"整个文件都是新增"渲染。
    public func fileContents(path: String) async throws -> String {
        let url = root.appendingPathComponent(path)
        let data = try Data(contentsOf: url)
        return String(decoding: data, as: UTF8.self)
    }

    /// 一次性拿到所有已跟踪文件的 +/− 行数，供文件列表展示。
    ///
    /// 两次 numstat 调用（暂存区与工作区）比逐文件算 diff 便宜得多，
    /// 这正是"文件列表要在 150ms 内出来"的做法——列表只需要数字，不需要内容。
    /// 未跟踪文件不在 numstat 输出里，列表中不显示行数。
    public func lineStats() async throws -> [String: LineStats] {
        async let stagedData = runner.run(["diff", "--numstat", "-z", "--cached"], in: root)
        async let unstagedData = runner.run(["diff", "--numstat", "-z"], in: root)
        let staged = NumstatParser.parse(try await stagedData)
        let unstaged = NumstatParser.parse(try await unstagedData)
        return staged.merging(unstaged) { $0.merging($1) }
    }

    /// 从任意路径向上查找仓库根目录。用户通过选择目录添加仓库时使用。
    public static func discoverRoot(at url: URL, runner: GitRunner) async throws -> URL {
        let data = try await runner.run(["rev-parse", "--show-toplevel"], in: url)
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path)
    }
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `swift test --filter GitKitTests`
Expected: GitKit 的全部测试通过（FixtureRepo 3 + GitRunner 5 + StatusParser 9 + WorktreeParser 4 + DiffParser 9 + GitRepository 9 = 39 个）。

- [ ] **Step 6: 提交**

```bash
git rm -f Sources/GitKit/Placeholder.swift 2>/dev/null || true
git add Sources/GitKit/NumstatParser.swift Sources/GitKit/GitRepository.swift Tests/GitKitTests/GitRepositoryTests.swift
git commit -m "feat(GitKit): 仓库门面与行数统计"
```

---

### Task 7: GeneratedFileDetector —— 生成文件识别

**Files:**
- Create: `Sources/DiffEngine/GeneratedFileDetector.swift`
- Create: `Tests/DiffEngineTests/GeneratedFileDetectorTests.swift`
- Delete: `Sources/DiffEngine/Placeholder.swift`

**Interfaces:**
- Produces: `GeneratedFileReason` 枚举（`.pathRule(String)`、`.tooManyLines(Int)`、`.tooLarge(Int)`）与 `GeneratedFileDetector` 结构体。`init(pathRules: [String] = GeneratedFileDetector.defaultPathRules, maximumLines: Int = 3000, maximumBytes: Int = 500_000)`；方法 `func reason(forPath path: String, lineCount: Int?, byteCount: Int?) -> GeneratedFileReason?`；静态属性 `defaultPathRules: [String]`。

- [ ] **Step 1: 写失败的测试**

`Tests/DiffEngineTests/GeneratedFileDetectorTests.swift`：

```swift
import XCTest
@testable import DiffEngine

final class GeneratedFileDetectorTests: XCTestCase {
    private let detector = GeneratedFileDetector()

    func testLockFilesAreGenerated() {
        XCTAssertNotNil(detector.reason(forPath: "pnpm-lock.yaml", lineCount: 10, byteCount: 100))
        XCTAssertNotNil(detector.reason(forPath: "package-lock.json", lineCount: 10, byteCount: 100))
        XCTAssertNotNil(detector.reason(forPath: "Cargo.lock", lineCount: 10, byteCount: 100))
    }

    func testBuildOutputDirectoriesAreGenerated() {
        XCTAssertNotNil(detector.reason(forPath: "dist/index.js", lineCount: 10, byteCount: 100))
        XCTAssertNotNil(detector.reason(forPath: "apps/web/build/main.css", lineCount: 10, byteCount: 100))
        XCTAssertNotNil(detector.reason(forPath: "node_modules/foo/index.js", lineCount: 10, byteCount: 100))
    }

    func testMinifiedAndSourceMapsAreGenerated() {
        XCTAssertNotNil(detector.reason(forPath: "assets/app.min.js", lineCount: 5, byteCount: 100))
        XCTAssertNotNil(detector.reason(forPath: "assets/app.js.map", lineCount: 5, byteCount: 100))
    }

    func testOrdinarySourceIsNotGenerated() {
        XCTAssertNil(detector.reason(forPath: "src/main.swift", lineCount: 200, byteCount: 5_000))
        XCTAssertNil(detector.reason(forPath: "apps/web/src/App.tsx", lineCount: 200, byteCount: 5_000))
    }

    /// 目录名恰好包含规则关键字，但不是那个目录，不应误判。
    func testDirectoryRuleMatchesPathComponentNotSubstring() {
        XCTAssertNil(detector.reason(forPath: "src/distribution/list.ts", lineCount: 10, byteCount: 100),
                     "distribution 不是 dist 目录")
        XCTAssertNil(detector.reason(forPath: "src/rebuild/index.ts", lineCount: 10, byteCount: 100),
                     "rebuild 不是 build 目录")
    }

    func testTooManyLines() {
        let reason = detector.reason(forPath: "src/huge.ts", lineCount: 5_000, byteCount: 10_000)
        guard case .tooManyLines(let count)? = reason else {
            return XCTFail("期望 tooManyLines，实际是 \(String(describing: reason))")
        }
        XCTAssertEqual(count, 5_000)
    }

    func testTooManyBytes() {
        let reason = detector.reason(forPath: "src/huge.ts", lineCount: 100, byteCount: 900_000)
        guard case .tooLarge? = reason else {
            return XCTFail("期望 tooLarge，实际是 \(String(describing: reason))")
        }
    }

    func testUnknownSizeIsNotGenerated() {
        XCTAssertNil(detector.reason(forPath: "src/main.swift", lineCount: nil, byteCount: nil))
    }

    func testCustomRulesReplaceDefaults() {
        let custom = GeneratedFileDetector(pathRules: ["*.generated.ts"])
        XCTAssertNotNil(custom.reason(forPath: "src/api.generated.ts", lineCount: 10, byteCount: 100))
        XCTAssertNil(custom.reason(forPath: "pnpm-lock.yaml", lineCount: 10, byteCount: 100),
                     "自定义规则应替换默认规则而非叠加")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter GeneratedFileDetectorTests`
Expected: 编译失败，报 `cannot find 'GeneratedFileDetector' in scope`。

- [ ] **Step 3: 实现**

`Sources/DiffEngine/GeneratedFileDetector.swift`：

```swift
import Foundation

public enum GeneratedFileReason: Sendable, Equatable {
    /// 命中了某条路径规则，附带规则本身，便于在 UI 中说明原因。
    case pathRule(String)
    case tooManyLines(Int)
    case tooLarge(Int)

    /// 展示给用户的说明文字。
    public var explanation: String {
        switch self {
        case .pathRule(let rule): "匹配规则 \(rule)"
        case .tooManyLines(let count): "共 \(count) 行"
        case .tooLarge(let bytes): "共 \(bytes / 1024) KB"
        }
    }
}

/// 判断一个文件是否应该默认折叠。命中的文件不读内容、不算 diff、不做高亮，
/// 只显示一个占位条，用户点击后才加载。
///
/// 这既是性能保护，也是产品功能——agent 的改动里往往混着大量 lockfile 和构建产物。
public struct GeneratedFileDetector: Sendable {
    /// 支持两种形式：以 `/` 结尾表示目录名（按路径段精确匹配，避免
    /// `distribution/` 被 `dist/` 误伤），否则按文件名做 glob 匹配。
    public static let defaultPathRules: [String] = [
        "dist/", "build/", "node_modules/", "vendor/", ".next/", "target/",
        "*.lock", "*-lock.json", "*.lockb",
        "*.min.js", "*.min.css", "*.map",
        "*.pb.go", "*_pb2.py", "*.generated.*", "*_generated.*",
    ]

    private let pathRules: [String]
    private let maximumLines: Int
    private let maximumBytes: Int

    public init(pathRules: [String] = GeneratedFileDetector.defaultPathRules,
                maximumLines: Int = 3_000,
                maximumBytes: Int = 500_000) {
        self.pathRules = pathRules
        self.maximumLines = maximumLines
        self.maximumBytes = maximumBytes
    }

    /// 返回折叠原因，nil 表示正常显示。
    /// `lineCount` 与 `byteCount` 未知时传 nil，此时只按路径规则判断。
    public func reason(forPath path: String, lineCount: Int?, byteCount: Int?) -> GeneratedFileReason? {
        let components = path.split(separator: "/").map(String.init)
        guard let fileName = components.last else { return nil }

        for rule in pathRules {
            if rule.hasSuffix("/") {
                let directoryName = String(rule.dropLast())
                // 按路径段精确匹配，不用子串包含。
                if components.dropLast().contains(directoryName) {
                    return .pathRule(rule)
                }
            } else if matchesGlob(fileName, pattern: rule) {
                return .pathRule(rule)
            }
        }

        if let lineCount, lineCount > maximumLines { return .tooManyLines(lineCount) }
        if let byteCount, byteCount > maximumBytes { return .tooLarge(byteCount) }
        return nil
    }

    /// fnmatch 的薄封装。规则里只会用到 `*` 和 `?`，交给系统实现即可。
    private func matchesGlob(_ name: String, pattern: String) -> Bool {
        pattern.withCString { patternPointer in
            name.withCString { namePointer in
                fnmatch(patternPointer, namePointer, 0) == 0
            }
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter GeneratedFileDetectorTests`
Expected: 9 个测试全部通过。

- [ ] **Step 5: 提交**

```bash
git rm -f Sources/DiffEngine/Placeholder.swift 2>/dev/null || true
git add Sources/DiffEngine/GeneratedFileDetector.swift Tests/DiffEngineTests/GeneratedFileDetectorTests.swift
git commit -m "feat(DiffEngine): 生成文件识别"
```

---

### Task 8: DiffCache 与 DiffEngine —— 懒加载与缓存

**Files:**
- Create: `Sources/DiffEngine/DiffCache.swift`
- Create: `Sources/DiffEngine/DiffEngine.swift`
- Create: `Tests/DiffEngineTests/DiffCacheTests.swift`
- Create: `Tests/DiffEngineTests/DiffEngineTests.swift`

**Interfaces:**
- Consumes: Task 6 的 `GitRepository`，Task 5 的 `FileDiff`，Task 7 的 `GeneratedFileDetector`。
- Produces:
  - `DiffCacheKey` 结构体（`worktreePath: URL`、`filePath: String`、`staged: Bool`，`Hashable`）。
  - `DiffCache` actor：`init(maximumEntries: Int = 50, maximumBytes: Int = 50_000_000)`、`func value(for key: DiffCacheKey) -> LoadedDiff?`、`func insert(_ value: LoadedDiff, for key: DiffCacheKey)`、`func removeAll()`、`func removeAll(inWorktree path: URL)`、`var count: Int { get }`。
  - `LoadedDiff` 枚举：`.ready(FileDiff)`、`.collapsed(reason: GeneratedFileReason, path: String)`。
  - `DiffEngine` actor：`init(detector: GeneratedFileDetector = GeneratedFileDetector(), cache: DiffCache = DiffCache())`、`func load(status: FileStatus, staged: Bool, from repository: GitRepository) async throws -> LoadedDiff`、`func loadIgnoringCollapse(status: FileStatus, staged: Bool, from repository: GitRepository) async throws -> LoadedDiff`、`func invalidate(worktreePath: URL)`。

- [ ] **Step 1: 写 DiffCache 的失败测试**

`Tests/DiffEngineTests/DiffCacheTests.swift`：

```swift
import XCTest
import GitKit
@testable import DiffEngine

final class DiffCacheTests: XCTestCase {
    private func key(_ file: String, worktree: String = "/w") -> DiffCacheKey {
        DiffCacheKey(worktreePath: URL(fileURLWithPath: worktree), filePath: file, staged: false)
    }

    private func diff(_ path: String, lines: Int = 1) -> LoadedDiff {
        let diffLines = (0..<lines).map {
            DiffLine(kind: .addition, oldLineNumber: nil, newLineNumber: $0 + 1, text: "x")
        }
        let hunk = Hunk(oldStart: 1, oldCount: 0, newStart: 1, newCount: lines,
                        sectionHeading: "", lines: diffLines)
        return .ready(FileDiff(path: path, originalPath: nil, content: .textual([hunk])))
    }

    func testStoresAndRetrieves() async {
        let cache = DiffCache()
        await cache.insert(diff("a.txt"), for: key("a.txt"))
        let value = await cache.value(for: key("a.txt"))
        XCTAssertNotNil(value)
    }

    func testMissReturnsNil() async {
        let cache = DiffCache()
        let value = await cache.value(for: key("missing.txt"))
        XCTAssertNil(value)
    }

    func testEvictsLeastRecentlyUsedWhenOverEntryLimit() async {
        let cache = DiffCache(maximumEntries: 2, maximumBytes: .max)
        await cache.insert(diff("a.txt"), for: key("a.txt"))
        await cache.insert(diff("b.txt"), for: key("b.txt"))
        // 读一下 a，让 b 成为最久未使用的那个。
        _ = await cache.value(for: key("a.txt"))
        await cache.insert(diff("c.txt"), for: key("c.txt"))

        let count = await cache.count
        XCTAssertEqual(count, 2)
        let a = await cache.value(for: key("a.txt"))
        let b = await cache.value(for: key("b.txt"))
        XCTAssertNotNil(a, "a 刚被访问过，不应被淘汰")
        XCTAssertNil(b, "b 是最久未使用的，应被淘汰")
    }

    func testEvictsWhenOverByteLimit() async {
        let cache = DiffCache(maximumEntries: .max, maximumBytes: 500)
        await cache.insert(diff("a.txt", lines: 100), for: key("a.txt"))
        await cache.insert(diff("b.txt", lines: 100), for: key("b.txt"))
        let count = await cache.count
        XCTAssertLessThan(count, 2, "总字节数超限时应淘汰旧条目")
    }

    func testRemoveAllInWorktreeLeavesOtherWorktrees() async {
        let cache = DiffCache()
        await cache.insert(diff("a.txt"), for: key("a.txt", worktree: "/w1"))
        await cache.insert(diff("a.txt"), for: key("a.txt", worktree: "/w2"))
        await cache.removeAll(inWorktree: URL(fileURLWithPath: "/w1"))

        let gone = await cache.value(for: key("a.txt", worktree: "/w1"))
        let kept = await cache.value(for: key("a.txt", worktree: "/w2"))
        XCTAssertNil(gone)
        XCTAssertNotNil(kept)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter DiffCacheTests`
Expected: 编译失败，报 `cannot find 'DiffCache' in scope`。

- [ ] **Step 3: 实现 DiffCache**

`Sources/DiffEngine/DiffCache.swift`：

```swift
import Foundation
import GitKit

public struct DiffCacheKey: Sendable, Hashable {
    public let worktreePath: URL
    public let filePath: String
    public let staged: Bool

    public init(worktreePath: URL, filePath: String, staged: Bool) {
        self.worktreePath = worktreePath
        self.filePath = filePath
        self.staged = staged
    }
}

public enum LoadedDiff: Sendable, Equatable {
    case ready(FileDiff)
    /// 生成文件或超大文件，默认不加载内容。
    case collapsed(reason: GeneratedFileReason, path: String)

    /// 估算内存占用，用于缓存容量控制。按每行约 80 字节粗算即可，
    /// 精确值不重要，重要的是大文件占更多份额。
    var estimatedBytes: Int {
        switch self {
        case .collapsed: 128
        case .ready(let diff): diff.hunks.reduce(0) { $0 + $1.lines.count * 80 } + 256
        }
    }
}

/// diff 结果的 LRU 缓存。默认上限 50 条或 50MB，先到者为准。
public actor DiffCache {
    private struct Entry {
        let value: LoadedDiff
        let bytes: Int
    }

    private var entries: [DiffCacheKey: Entry] = [:]
    /// 访问顺序，末尾是最近使用的。
    private var accessOrder: [DiffCacheKey] = []
    private var totalBytes = 0

    private let maximumEntries: Int
    private let maximumBytes: Int

    public init(maximumEntries: Int = 50, maximumBytes: Int = 50_000_000) {
        self.maximumEntries = maximumEntries
        self.maximumBytes = maximumBytes
    }

    public var count: Int { entries.count }

    public func value(for key: DiffCacheKey) -> LoadedDiff? {
        guard let entry = entries[key] else { return nil }
        touch(key)
        return entry.value
    }

    public func insert(_ value: LoadedDiff, for key: DiffCacheKey) {
        if let existing = entries[key] {
            totalBytes -= existing.bytes
        }
        let bytes = value.estimatedBytes
        entries[key] = Entry(value: value, bytes: bytes)
        totalBytes += bytes
        touch(key)
        evictIfNeeded()
    }

    public func removeAll() {
        entries.removeAll()
        accessOrder.removeAll()
        totalBytes = 0
    }

    /// 某个 worktree 的文件发生变化时，只清该 worktree 的缓存。
    public func removeAll(inWorktree path: URL) {
        let doomed = entries.keys.filter { $0.worktreePath == path }
        for key in doomed { remove(key) }
    }

    private func touch(_ key: DiffCacheKey) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func remove(_ key: DiffCacheKey) {
        if let entry = entries.removeValue(forKey: key) {
            totalBytes -= entry.bytes
        }
        accessOrder.removeAll { $0 == key }
    }

    private func evictIfNeeded() {
        while (entries.count > maximumEntries || totalBytes > maximumBytes),
              let oldest = accessOrder.first {
            remove(oldest)
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter DiffCacheTests`
Expected: 5 个测试全部通过。

- [ ] **Step 5: 写 DiffEngine 的失败测试**

`Tests/DiffEngineTests/DiffEngineTests.swift`：

```swift
import XCTest
import GitKit
@testable import DiffEngine

final class DiffEngineTests: XCTestCase {
    /// 在临时目录里建一个真仓库。DiffEngineTests 无法访问 GitKitTests 里的
    /// FixtureRepo，所以这里放一个最小版本。
    private func makeRepository() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: url)
        try runGit(["config", "user.email", "t@sift.local"], in: url)
        try runGit(["config", "user.name", "T"], in: url)
        return url
    }

    private func runGit(_ args: [String], in url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = url
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    private func write(_ contents: String, to path: String, in url: URL) throws {
        let target = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: target, atomically: true, encoding: .utf8)
    }

    func testLoadsTextualDiff() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("line1\nline2\n", to: "a.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("line1\nCHANGED\n", to: "a.txt", in: url)

        let repository = GitRepository(root: url)
        let engine = DiffEngine()
        let status = try await repository.status()
        let loaded = try await engine.load(status: status[0], staged: false, from: repository)

        guard case .ready(let diff) = loaded else {
            return XCTFail("期望 ready，实际是 \(loaded)")
        }
        XCTAssertEqual(diff.addedLineCount, 1)
    }

    func testCollapsesGeneratedFile() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("{}\n", to: "package-lock.json", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("{\"changed\": true}\n", to: "package-lock.json", in: url)

        let repository = GitRepository(root: url)
        let engine = DiffEngine()
        let status = try await repository.status()
        let loaded = try await engine.load(status: status[0], staged: false, from: repository)

        guard case .collapsed(let reason, let path) = loaded else {
            return XCTFail("期望 collapsed，实际是 \(loaded)")
        }
        XCTAssertEqual(path, "package-lock.json")
        XCTAssertEqual(reason, .pathRule("*-lock.json"))
    }

    func testLoadIgnoringCollapseForcesLoad() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("{}\n", to: "package-lock.json", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("{\"changed\": true}\n", to: "package-lock.json", in: url)

        let repository = GitRepository(root: url)
        let engine = DiffEngine()
        let status = try await repository.status()
        let loaded = try await engine.loadIgnoringCollapse(
            status: status[0], staged: false, from: repository)

        guard case .ready = loaded else {
            return XCTFail("强制加载时应返回 ready，实际是 \(loaded)")
        }
    }

    func testUntrackedFileRendersAsAllAdded() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("seed\n", to: "seed.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("new line 1\nnew line 2\nnew line 3\n", to: "fresh.txt", in: url)

        let repository = GitRepository(root: url)
        let engine = DiffEngine()
        let status = try await repository.status()
        let untracked = try XCTUnwrap(status.first { $0.isUntracked })
        let loaded = try await engine.load(status: untracked, staged: false, from: repository)

        guard case .ready(let diff) = loaded else {
            return XCTFail("期望 ready，实际是 \(loaded)")
        }
        XCTAssertEqual(diff.addedLineCount, 3, "未跟踪文件应整个渲染为新增")
        XCTAssertEqual(diff.deletedLineCount, 0)
        XCTAssertEqual(diff.hunks.first?.newStart, 1)
    }

    func testSecondLoadHitsCache() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("line1\n", to: "a.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("changed\n", to: "a.txt", in: url)

        let repository = GitRepository(root: url)
        let cache = DiffCache()
        let engine = DiffEngine(cache: cache)
        let status = try await repository.status()

        _ = try await engine.load(status: status[0], staged: false, from: repository)
        let cached = await cache.value(for: DiffCacheKey(
            worktreePath: url, filePath: "a.txt", staged: false))
        XCTAssertNotNil(cached, "首次加载后应写入缓存")
    }
}
```

- [ ] **Step 6: 跑测试确认失败**

Run: `swift test --filter DiffEngineTests`
Expected: 编译失败，报 `cannot find 'DiffEngine' in scope`。

- [ ] **Step 7: 实现 DiffEngine**

`Sources/DiffEngine/DiffEngine.swift`：

```swift
import Foundation
import GitKit

/// diff 加载的唯一入口。负责三件事：判断是否折叠、查缓存、把未跟踪文件
/// 伪造成"整个文件都是新增"的 diff。
public actor DiffEngine {
    private let detector: GeneratedFileDetector
    private let cache: DiffCache

    public init(detector: GeneratedFileDetector = GeneratedFileDetector(),
                cache: DiffCache = DiffCache()) {
        self.detector = detector
        self.cache = cache
    }

    /// 加载单个文件的 diff。命中生成文件规则时返回 `.collapsed` 且不读取内容。
    public func load(status: FileStatus, staged: Bool,
                     from repository: GitRepository) async throws -> LoadedDiff {
        try await load(status: status, staged: staged,
                       from: repository, ignoringCollapse: false)
    }

    /// 用户在占位条上点了"仍要查看"时调用，跳过折叠判断。
    public func loadIgnoringCollapse(status: FileStatus, staged: Bool,
                                     from repository: GitRepository) async throws -> LoadedDiff {
        try await load(status: status, staged: staged,
                       from: repository, ignoringCollapse: true)
    }

    public func invalidate(worktreePath: URL) async {
        await cache.removeAll(inWorktree: worktreePath)
    }

    private func load(status: FileStatus, staged: Bool,
                      from repository: GitRepository,
                      ignoringCollapse: Bool) async throws -> LoadedDiff {
        let key = DiffCacheKey(worktreePath: repository.root,
                               filePath: status.path, staged: staged)

        if let cached = await cache.value(for: key) {
            // 折叠占位不算命中——用户明确要求强制加载时得真的去读。
            if !(ignoringCollapse && isCollapsed(cached)) {
                return cached
            }
        }

        if !ignoringCollapse,
           let reason = detector.reason(forPath: status.path, lineCount: nil, byteCount: nil) {
            let result = LoadedDiff.collapsed(reason: reason, path: status.path)
            await cache.insert(result, for: key)
            return result
        }

        let diff: FileDiff
        if status.isUntracked {
            diff = try await untrackedDiff(status: status, repository: repository,
                                           ignoringCollapse: ignoringCollapse)
        } else {
            diff = try await repository.diff(path: status.path, staged: staged)
        }

        // 内容读出来之后才知道真实体量，这里再判一次行数与字节数。
        if !ignoringCollapse {
            let lineCount = diff.hunks.reduce(0) { $0 + $1.lines.count }
            if let reason = detector.reason(forPath: status.path,
                                            lineCount: lineCount, byteCount: nil) {
                let result = LoadedDiff.collapsed(reason: reason, path: status.path)
                await cache.insert(result, for: key)
                return result
            }
        }

        let result = LoadedDiff.ready(diff)
        await cache.insert(result, for: key)
        return result
    }

    /// 未跟踪文件在 git 眼里没有 diff，这里按"整个文件都是新增"合成一个。
    private func untrackedDiff(status: FileStatus, repository: GitRepository,
                               ignoringCollapse: Bool) async throws -> FileDiff {
        let contents = try await repository.fileContents(path: status.path)
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        // 以换行结尾时 split 会多出一个空串，去掉它。
        if contents.hasSuffix("\n"), lines.last == "" { lines.removeLast() }

        let diffLines = lines.enumerated().map { offset, text in
            DiffLine(kind: .addition, oldLineNumber: nil,
                     newLineNumber: offset + 1, text: text)
        }
        let hunk = Hunk(oldStart: 0, oldCount: 0,
                        newStart: 1, newCount: diffLines.count,
                        sectionHeading: "", lines: diffLines)
        return FileDiff(path: status.path, originalPath: nil,
                        content: diffLines.isEmpty ? .empty : .textual([hunk]))
    }

    private func isCollapsed(_ diff: LoadedDiff) -> Bool {
        if case .collapsed = diff { return true }
        return false
    }
}
```

- [ ] **Step 8: 跑测试确认通过**

Run: `swift test --filter DiffEngineTests`
Expected: 5 个测试全部通过。

- [ ] **Step 9: 提交**

```bash
git add Sources/DiffEngine Tests/DiffEngineTests
git commit -m "feat(DiffEngine): 懒加载、LRU 缓存与未跟踪文件处理"
```

---

### Task 9: FileTreeBuilder —— 扁平路径转树

**Files:**
- Create: `Sources/DiffEngine/FileTreeBuilder.swift`
- Create: `Tests/DiffEngineTests/FileTreeBuilderTests.swift`

**Interfaces:**
- Consumes: Task 3 的 `FileStatus`。
- Produces: `FileTreeNode` 枚举（`indirect`，case 为 `.directory(name: String, path: String, children: [FileTreeNode])` 与 `.file(FileStatus)`）与 `FileTreeBuilder.build(from statuses: [FileStatus], collapsingSingleChildDirectories: Bool) -> [FileTreeNode]`。

- [ ] **Step 1: 写失败的测试**

`Tests/DiffEngineTests/FileTreeBuilderTests.swift`：

```swift
import XCTest
import GitKit
@testable import DiffEngine

final class FileTreeBuilderTests: XCTestCase {
    private func status(_ path: String) -> FileStatus {
        FileStatus(path: path, originalPath: nil,
                   indexStatus: .unmodified, worktreeStatus: .modified)
    }

    private func names(_ nodes: [FileTreeNode]) -> [String] {
        nodes.map { node in
            switch node {
            case .directory(let name, _, _): name
            case .file(let status): status.fileName
            }
        }
    }

    func testFlatFilesProduceFlatTree() {
        let tree = FileTreeBuilder.build(
            from: [status("a.txt"), status("b.txt")],
            collapsingSingleChildDirectories: false)
        XCTAssertEqual(names(tree), ["a.txt", "b.txt"])
    }

    func testNestedPathsProduceDirectories() {
        let tree = FileTreeBuilder.build(
            from: [status("src/main.swift"), status("src/util.swift"), status("README.md")],
            collapsingSingleChildDirectories: false)
        // 目录排在文件前面，各自按名称排序。
        XCTAssertEqual(names(tree), ["src", "README.md"])
        guard case .directory(_, _, let children) = tree[0] else {
            return XCTFail("第一个节点应是目录")
        }
        XCTAssertEqual(names(children), ["main.swift", "util.swift"])
    }

    func testDirectoryPathIsFullPath() {
        let tree = FileTreeBuilder.build(
            from: [status("apps/web/src/App.tsx")],
            collapsingSingleChildDirectories: false)
        guard case .directory(let name, let path, _) = tree[0] else {
            return XCTFail("应是目录")
        }
        XCTAssertEqual(name, "apps")
        XCTAssertEqual(path, "apps")
    }

    func testCollapsesSingleChildDirectoryChains() {
        let tree = FileTreeBuilder.build(
            from: [status("apps/web/src/App.tsx")],
            collapsingSingleChildDirectories: true)
        XCTAssertEqual(names(tree), ["apps/web/src"],
                       "只有一个子节点的目录链应压成一行，避免无意义的层层缩进")
        guard case .directory(_, let path, let children) = tree[0] else {
            return XCTFail("应是目录")
        }
        XCTAssertEqual(path, "apps/web/src")
        XCTAssertEqual(names(children), ["App.tsx"])
    }

    func testDoesNotCollapseWhenDirectoryHasMultipleChildren() {
        let tree = FileTreeBuilder.build(
            from: [status("src/a.swift"), status("src/nested/b.swift")],
            collapsingSingleChildDirectories: true)
        XCTAssertEqual(names(tree), ["src"])
        guard case .directory(_, _, let children) = tree[0] else {
            return XCTFail("应是目录")
        }
        XCTAssertEqual(names(children), ["nested", "a.swift"])
    }

    func testSortsDirectoriesBeforeFilesAlphabetically() {
        let tree = FileTreeBuilder.build(
            from: [status("z.txt"), status("a.txt"), status("beta/x.txt"), status("alpha/y.txt")],
            collapsingSingleChildDirectories: false)
        XCTAssertEqual(names(tree), ["alpha", "beta", "a.txt", "z.txt"])
    }

    func testEmptyInputProducesEmptyTree() {
        XCTAssertTrue(FileTreeBuilder.build(from: [], collapsingSingleChildDirectories: true).isEmpty)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter FileTreeBuilderTests`
Expected: 编译失败，报 `cannot find 'FileTreeBuilder' in scope`。

- [ ] **Step 3: 实现**

`Sources/DiffEngine/FileTreeBuilder.swift`：

```swift
import Foundation
import GitKit

public indirect enum FileTreeNode: Sendable, Identifiable {
    case directory(name: String, path: String, children: [FileTreeNode])
    case file(FileStatus)

    public var id: String {
        switch self {
        case .directory(_, let path, _): "dir:" + path
        case .file(let status): "file:" + status.path
        }
    }
}

/// 把扁平的改动文件列表转成目录树。纯函数，没有任何副作用。
public enum FileTreeBuilder {
    /// - Parameter collapsingSingleChildDirectories: 为 true 时把只含一个子目录的
    ///   目录链压成一行（`apps/web/src`），避免 monorepo 里层层无意义的缩进。
    public static func build(from statuses: [FileStatus],
                             collapsingSingleChildDirectories: Bool) -> [FileTreeNode] {
        var root = MutableDirectory(name: "", path: "")
        for status in statuses {
            let components = status.path.split(separator: "/").map(String.init)
            root.insert(status: status, components: components, depth: 0)
        }
        var children = root.materialize()
        if collapsingSingleChildDirectories {
            children = children.map(collapse)
        }
        return children
    }

    private static func collapse(_ node: FileTreeNode) -> FileTreeNode {
        guard case .directory(let name, let path, let children) = node else { return node }
        // 恰好一个子节点且该子节点是目录时，把两层合成一层，然后继续往下压。
        if children.count == 1,
           case .directory(let childName, let childPath, let grandchildren) = children[0] {
            return collapse(.directory(name: "\(name)/\(childName)",
                                       path: childPath,
                                       children: grandchildren))
        }
        return .directory(name: name, path: path, children: children.map(collapse))
    }

    /// 构建期使用的可变中间结构。
    private struct MutableDirectory {
        let name: String
        let path: String
        var subdirectories: [String: MutableDirectory] = [:]
        var files: [FileStatus] = []

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }

        mutating func insert(status: FileStatus, components: [String], depth: Int) {
            guard depth < components.count - 1 else {
                files.append(status)
                return
            }
            let childName = components[depth]
            let childPath = path.isEmpty ? childName : "\(path)/\(childName)"
            var child = subdirectories[childName] ?? MutableDirectory(name: childName, path: childPath)
            child.insert(status: status, components: components, depth: depth + 1)
            subdirectories[childName] = child
        }

        func materialize() -> [FileTreeNode] {
            let directoryNodes = subdirectories.values
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { FileTreeNode.directory(name: $0.name, path: $0.path,
                                              children: $0.materialize()) }
            let fileNodes = files
                .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
                .map { FileTreeNode.file($0) }
            return directoryNodes + fileNodes
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter FileTreeBuilderTests`
Expected: 7 个测试全部通过。

- [ ] **Step 5: 提交**

```bash
git add Sources/DiffEngine/FileTreeBuilder.swift Tests/DiffEngineTests/FileTreeBuilderTests.swift
git commit -m "feat(DiffEngine): 文件树构建"
```

---

### Task 10: PersistedState 与 RepoStore —— 状态与持久化

**Files:**
- Create: `Sources/RepoStore/PersistedState.swift`
- Create: `Sources/RepoStore/RepoStore.swift`
- Create: `Tests/RepoStoreTests/PersistedStateTests.swift`
- Delete: `Sources/RepoStore/Placeholder.swift`

**Interfaces:**
- Consumes: Task 4 的 `Worktree`、Task 3 的 `FileStatus`、Task 6 的 `GitRepository`、Task 8 的 `DiffEngine` 与 `LoadedDiff`。
- Produces:
  - `PersistedState` 结构体（`Codable`）：`repositoryBookmarks: [Data]`、`selectedWorktreePath: String?`、`usesTreeView: Bool`。
  - `PersistedStateStore` 结构体：`init(fileURL: URL)`、`func load() -> PersistedState`、`func save(_ state: PersistedState) throws`、静态属性 `defaultFileURL: URL`。
  - `RepositoryEntry` 结构体：`root: URL`、`name: String`、`worktrees: [Worktree]`，`Identifiable` by `root`。
  - `RepoStore` 类（`@MainActor @Observable`）：属性 `repositories: [RepositoryEntry]`、`selectedWorktree: Worktree?`、`fileStatuses: [FileStatus]`、`selectedFile: FileStatus?`、`selectedFileIsStaged: Bool`、`loadedDiff: LoadedDiff?`、`usesTreeView: Bool`、`isLoadingFileList: Bool`、`errorMessage: String?`；方法 `func addRepository(at url: URL) async`、`func removeRepository(root: URL)`、`func select(worktree: Worktree) async`、`func select(file: FileStatus, staged: Bool) async`、`func expandCollapsedDiff() async`、`func refreshFileList() async`、`func restore() async`。

- [ ] **Step 1: 写 PersistedState 的失败测试**

`Tests/RepoStoreTests/PersistedStateTests.swift`：

```swift
import XCTest
@testable import RepoStore

final class PersistedStateTests: XCTestCase {
    private func temporaryFile() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-state-\(UUID().uuidString)/state.json")
    }

    func testLoadReturnsEmptyStateWhenFileMissing() {
        let store = PersistedStateStore(fileURL: temporaryFile())
        let state = store.load()
        XCTAssertTrue(state.repositoryBookmarks.isEmpty)
        XCTAssertNil(state.selectedWorktreePath)
    }

    func testRoundTrip() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = PersistedStateStore(fileURL: url)
        let original = PersistedState(
            repositoryBookmarks: [Data([1, 2, 3])],
            selectedWorktreePath: "/repos/main",
            usesTreeView: true)
        try store.save(original)

        let loaded = PersistedStateStore(fileURL: url).load()
        XCTAssertEqual(loaded.repositoryBookmarks, [Data([1, 2, 3])])
        XCTAssertEqual(loaded.selectedWorktreePath, "/repos/main")
        XCTAssertTrue(loaded.usesTreeView)
    }

    func testSaveCreatesIntermediateDirectories() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PersistedStateStore(fileURL: url)
        try store.save(PersistedState(repositoryBookmarks: [], selectedWorktreePath: nil, usesTreeView: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// 磁盘上的 JSON 损坏时必须优雅降级，不能让应用启动不了。
    func testCorruptFileFallsBackToEmptyState() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("this is not json".utf8).write(to: url)

        let state = PersistedStateStore(fileURL: url).load()
        XCTAssertTrue(state.repositoryBookmarks.isEmpty)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter PersistedStateTests`
Expected: 编译失败，报 `cannot find 'PersistedStateStore' in scope`。

- [ ] **Step 3: 实现 PersistedState**

`Sources/RepoStore/PersistedState.swift`：

```swift
import Foundation

public struct PersistedState: Codable, Sendable, Equatable {
    /// security-scoped 书签。沙盒环境下重启后仍能访问用户选过的目录，
    /// 存路径字符串是不够的。
    public var repositoryBookmarks: [Data]
    public var selectedWorktreePath: String?
    public var usesTreeView: Bool

    public init(repositoryBookmarks: [Data] = [],
                selectedWorktreePath: String? = nil,
                usesTreeView: Bool = false) {
        self.repositoryBookmarks = repositoryBookmarks
        self.selectedWorktreePath = selectedWorktreePath
        self.usesTreeView = usesTreeView
    }
}

public struct PersistedStateStore: Sendable {
    private let fileURL: URL

    public init(fileURL: URL = PersistedStateStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    public static var defaultFileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Sift/state.json")
    }

    /// 读失败一律返回空状态。用户的偏好设置丢了是小事，启动不了是大事。
    public func load() -> PersistedState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return PersistedState() }
        return state
    }

    public func save(_ state: PersistedState) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter PersistedStateTests`
Expected: 4 个测试全部通过。

- [ ] **Step 5: 实现 RepoStore**

这个类是 UI 的唯一数据源，不写自动化测试（它的组成部分已各自测过），在 Task 12 中手动验证。

`Sources/RepoStore/RepoStore.swift`：

```swift
import Foundation
import Observation
import GitKit
import DiffEngine

public struct RepositoryEntry: Identifiable, Sendable {
    public let root: URL
    public let name: String
    public var worktrees: [Worktree]
    public var id: URL { root }
}

/// UI 的唯一数据源。所有 git 工作都通过 async 方法发起，
/// 结果回到主线程后才写入被观察的属性。
@MainActor
@Observable
public final class RepoStore {
    public private(set) var repositories: [RepositoryEntry] = []
    public private(set) var selectedWorktree: Worktree?
    public private(set) var fileStatuses: [FileStatus] = []
    /// 文件路径到 +/− 行数的映射。未跟踪文件不在其中。
    public private(set) var lineStats: [String: LineStats] = [:]
    public private(set) var selectedFile: FileStatus?
    public private(set) var selectedFileIsStaged = false
    public private(set) var loadedDiff: LoadedDiff?
    public private(set) var isLoadingFileList = false
    public var errorMessage: String?

    public var usesTreeView: Bool {
        didSet { persist() }
    }

    private let engine = DiffEngine()
    private let stateStore: PersistedStateStore
    private var watcher: FileSystemWatcher?

    /// 在途任务句柄。切换选择时取消旧任务——这是"切换即取消"约束的落点。
    private var fileListTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?

    public init(stateStore: PersistedStateStore = PersistedStateStore()) {
        self.stateStore = stateStore
        self.usesTreeView = stateStore.load().usesTreeView
    }

    // MARK: - 仓库管理

    public func addRepository(at url: URL) async {
        do {
            let root = try await GitRepository.discoverRoot(at: url, runner: GitRunner())
            guard !repositories.contains(where: { $0.root == root }) else { return }
            let worktrees = try await GitRepository(root: root).worktrees()
            repositories.append(RepositoryEntry(
                root: root, name: root.lastPathComponent, worktrees: worktrees))
            persist()
            if selectedWorktree == nil, let first = worktrees.first {
                await select(worktree: first)
            }
        } catch {
            errorMessage = "无法添加仓库：\(error)"
        }
    }

    public func removeRepository(root: URL) {
        repositories.removeAll { $0.root == root }
        if let selected = selectedWorktree,
           !repositories.contains(where: { $0.worktrees.contains(selected) }) {
            selectedWorktree = nil
            fileStatuses = []
            selectedFile = nil
            loadedDiff = nil
            watcher = nil
        }
        persist()
    }

    // MARK: - 选择

    public func select(worktree: Worktree) async {
        guard selectedWorktree != worktree else { return }
        // 切换 worktree：取消旧的所有在途工作。
        fileListTask?.cancel()
        diffTask?.cancel()

        selectedWorktree = worktree
        selectedFile = nil
        loadedDiff = nil
        fileStatuses = []
        persist()

        startWatching(worktree)
        await refreshFileList()
    }

    public func select(file: FileStatus, staged: Bool) async {
        diffTask?.cancel()
        selectedFile = file
        selectedFileIsStaged = staged
        loadedDiff = nil

        guard let worktree = selectedWorktree else { return }
        let repository = GitRepository(root: worktree.path)
        let engine = self.engine

        diffTask = Task { [weak self] in
            do {
                let diff = try await engine.load(status: file, staged: staged, from: repository)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.selectedFile == file else { return }
                    self.loadedDiff = diff
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.errorMessage = "无法加载 diff：\(error)" }
            }
        }
        await diffTask?.value
    }

    /// 用户在折叠占位条上点了"仍要查看"。
    public func expandCollapsedDiff() async {
        guard let file = selectedFile, let worktree = selectedWorktree else { return }
        let repository = GitRepository(root: worktree.path)
        do {
            loadedDiff = try await engine.loadIgnoringCollapse(
                status: file, staged: selectedFileIsStaged, from: repository)
        } catch {
            errorMessage = "无法加载 diff：\(error)"
        }
    }

    // MARK: - 刷新

    public func refreshFileList() async {
        guard let worktree = selectedWorktree else { return }
        fileListTask?.cancel()
        isLoadingFileList = true

        let repository = GitRepository(root: worktree.path)
        let engine = self.engine

        fileListTask = Task { [weak self] in
            do {
                await engine.invalidate(worktreePath: worktree.path)
                // status 与 numstat 并发发起——两者互不依赖，串行等待是白白浪费预算。
                async let statusResult = repository.status()
                async let statsResult = repository.lineStats()
                let statuses = try await statusResult
                let stats = try await statsResult
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.selectedWorktree == worktree else { return }
                    self.fileStatuses = statuses
                    self.lineStats = stats
                    self.isLoadingFileList = false
                    // 之前选中的文件如果还在，重新加载它的 diff。
                    if let selected = self.selectedFile,
                       !statuses.contains(where: { $0.path == selected.path }) {
                        self.selectedFile = nil
                        self.loadedDiff = nil
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.isLoadingFileList = false
                    self?.errorMessage = "无法读取文件状态：\(error)"
                }
            }
        }
        await fileListTask?.value
    }

    public func restore() async {
        let state = stateStore.load()
        for bookmark in state.repositoryBookmarks {
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark,
                                     options: .withSecurityScope,
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &isStale),
                  !isStale else { continue }
            _ = url.startAccessingSecurityScopedResource()
            await addRepository(at: url)
        }
        if let path = state.selectedWorktreePath {
            let target = URL(fileURLWithPath: path)
            let worktree = repositories.flatMap(\.worktrees).first { $0.path == target }
            if let worktree { await select(worktree: worktree) }
        }
    }

    // MARK: - 私有

    private func startWatching(_ worktree: Worktree) {
        watcher = FileSystemWatcher(path: worktree.path, debounce: .milliseconds(100)) { [weak self] in
            Task { @MainActor in await self?.refreshFileList() }
        }
    }

    private func persist() {
        let bookmarks = repositories.compactMap { entry in
            try? entry.root.bookmarkData(options: .withSecurityScope,
                                         includingResourceValuesForKeys: nil,
                                         relativeTo: nil)
        }
        let state = PersistedState(
            repositoryBookmarks: bookmarks,
            selectedWorktreePath: selectedWorktree?.path.path,
            usesTreeView: usesTreeView)
        try? stateStore.save(state)
    }
}
```

- [ ] **Step 6: 写 FileSystemWatcher 的空实现**

`RepoStore` 引用了 `FileSystemWatcher`，但真正的 FSEvents 实现在 Task 11。这里先放一个接口一致、什么都不做的版本，保证本任务结束时包可以编译、测试可以跑。Task 11 会替换它的内部实现，接口不变。

`Sources/RepoStore/FileSystemWatcher.swift`：

```swift
import Foundation

/// 占位实现。Task 11 会换成真正的 FSEvents 版本，接口保持不变。
public final class FileSystemWatcher: @unchecked Sendable {
    public init(path: URL, debounce: Duration = .milliseconds(100),
                onChange: @escaping @Sendable () -> Void) {
        // Task 11 实现。
    }
}
```

- [ ] **Step 7: 确认包可编译、测试通过**

Run: `swift build && swift test`
Expected: 构建成功，全部测试通过（69 个）。此时应用逻辑已完整，只是文件变更还不会自动刷新。

- [ ] **Step 8: 提交**

```bash
git rm -f Sources/RepoStore/Placeholder.swift 2>/dev/null || true
git add Sources/RepoStore Tests/RepoStoreTests
git commit -m "feat(RepoStore): 状态容器与持久化"
```

---

### Task 11: FileSystemWatcher —— FSEvents 与防抖

**Files:**
- Modify: `Sources/RepoStore/FileSystemWatcher.swift`（替换 Task 10 的空实现）
- Create: `Tests/RepoStoreTests/FileSystemWatcherTests.swift`

**Interfaces:**
- Consumes: Task 10 建立的 `FileSystemWatcher` 接口，签名保持不变。
- Produces: `FileSystemWatcher` 类的真实实现。`init(path: URL, debounce: Duration = .milliseconds(100), onChange: @escaping @Sendable () -> Void)`；析构时自动停止监听。

- [ ] **Step 1: 写失败的测试**

`Tests/RepoStoreTests/FileSystemWatcherTests.swift`：

```swift
import XCTest
@testable import RepoStore

final class FileSystemWatcherTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testFiresWhenFileIsWritten() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fired = expectation(description: "监听器触发")
        fired.assertForOverFulfill = false
        let watcher = FileSystemWatcher(path: directory, debounce: .milliseconds(100)) {
            fired.fulfill()
        }
        withExtendedLifetime(watcher) {
            // FSEvents 需要一点时间完成注册。
            Thread.sleep(forTimeInterval: 0.3)
            try? "hello".write(to: directory.appendingPathComponent("a.txt"),
                               atomically: true, encoding: .utf8)
            wait(for: [fired], timeout: 5)
        }
    }

    /// 防抖是硬性要求：agent 一次写入几十个文件不应触发几十次全量刷新。
    func testBurstOfWritesCoalescesIntoFewCallbacks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let counter = Counter()
        let watcher = FileSystemWatcher(path: directory, debounce: .milliseconds(200)) {
            counter.increment()
        }
        withExtendedLifetime(watcher) {
            Thread.sleep(forTimeInterval: 0.3)
            for index in 0..<50 {
                try? "x".write(to: directory.appendingPathComponent("f\(index).txt"),
                               atomically: true, encoding: .utf8)
            }
            Thread.sleep(forTimeInterval: 1.5)
        }
        let count = counter.value
        XCTAssertGreaterThan(count, 0, "至少应触发一次")
        XCTAssertLessThanOrEqual(count, 3, "50 次写入应被合并成很少几次，实际 \(count) 次")
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0
        func increment() { lock.lock(); storage += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter FileSystemWatcherTests`
Expected: 能编译（Task 10 的空实现让接口存在），但两个测试都失败——第一个超时后报"监听器触发"未满足，第二个报触发次数为 0。

- [ ] **Step 3: 用真实实现替换空实现**

把 `Sources/RepoStore/FileSystemWatcher.swift` 的全部内容替换为：

```swift
import Foundation
import CoreServices

/// 基于 FSEvents 的目录监听，带防抖。
///
/// 这是"永不轮询"这条约束的落点。Sourcetree 给每个书签仓库挂定时器，
/// 于是空闲时 CPU 永远不为零——我们只在文件真的变了的时候才做事。
///
/// 防抖同样是硬性要求：AI agent 一次提交常常连续写入几十个文件，
/// 没有合并窗口就会触发几十次全量 status 刷新。
public final class FileSystemWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "app.sift.fswatch", qos: .utility)
    private let debounce: Duration
    private let onChange: @Sendable () -> Void
    private var pendingWork: DispatchWorkItem?
    private let lock = NSLock()

    public init(path: URL, debounce: Duration = .milliseconds(100),
                onChange: @escaping @Sendable () -> Void) {
        self.debounce = debounce
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.scheduleCallback()
        }

        // latency 交给 FSEvents 做第一层合并，我们自己的 debounce 做第二层。
        let latency = Double(debounce.components.seconds)
            + Double(debounce.components.attoseconds) / 1e18

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))

        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        lock.lock()
        pendingWork?.cancel()
        lock.unlock()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// 每次事件都把已排队的回调往后推，直到安静满一个 debounce 窗口才真正执行。
    private func scheduleCallback() {
        lock.lock()
        pendingWork?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        pendingWork = work
        lock.unlock()

        let milliseconds = Int(Double(debounce.components.seconds) * 1000
            + Double(debounce.components.attoseconds) / 1e15)
        queue.asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: work)
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter FileSystemWatcherTests`
Expected: 2 个测试通过。

- [ ] **Step 5: 确认整个包恢复可编译**

Run: `swift build && swift test`
Expected: 构建成功，全部测试通过（71 个）。

- [ ] **Step 6: 提交**

```bash
git add Sources/RepoStore/FileSystemWatcher.swift Tests/RepoStoreTests/FileSystemWatcherTests.swift
git commit -m "feat(RepoStore): FSEvents 监听与防抖"
```

---

### Task 12: 应用壳与三栏界面

**Files:**
- Create: `App/Sift.xcodeproj`（通过 Xcode 创建）
- Create: `App/Sift/SiftApp.swift`
- Create: `Sources/SiftUI/Theme.swift`
- Create: `Sources/SiftUI/ContentView.swift`
- Create: `Sources/SiftUI/SourceSidebar.swift`
- Create: `Sources/SiftUI/FileListPane.swift`
- Delete: `Sources/SiftUI/Placeholder.swift`

**Interfaces:**
- Consumes: Task 10 的 `RepoStore`（含 `lineStats` 属性）与 `RepositoryEntry`，Task 9 的 `FileTreeBuilder` 与 `FileTreeNode`，Task 3 的 `FileStatus`，Task 4 的 `Worktree`，Task 6 的 `LineStats`。
- Produces: `ContentView`（无参数初始化，从环境读取 `RepoStore`）、`Theme` 枚举（静态属性 `codeFont: Font`、`interfaceFont: Font`、`additionBackground: Color`、`deletionBackground: Color`、`additionGutter: Color`、`deletionGutter: Color`）。

- [ ] **Step 1: 创建 Xcode 应用壳**

在 Xcode 中新建 macOS App 项目，名称 `Sift`，界面选 SwiftUI，语言 Swift，保存到 `App/`。然后：

1. 项目设置中把 Deployment Target 设为 macOS 26.0。
2. File → Add Package Dependencies → Add Local，选择仓库根目录，把 `SiftUI` 库加入 app target。
3. 关闭 App Sandbox（Signing & Capabilities 中移除 App Sandbox），否则 shell out 调 git 会被拦。这一步很关键，漏掉会表现为"所有 git 命令都失败"。

- [ ] **Step 2: 写应用入口**

`App/Sift/SiftApp.swift`：

```swift
import SwiftUI
import RepoStore
import SiftUI

@main
struct SiftApp: App {
    @State private var store = RepoStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .task { await store.restore() }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("添加仓库…") {
                    NotificationCenter.default.post(name: .siftAddRepository, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
```

- [ ] **Step 3: 写 Theme**

`Sources/SiftUI/Theme.swift`：

```swift
import SwiftUI

/// 视觉规范的唯一出口。颜色一律走系统语义色，
/// 只有 diff 的增删色是自定义的——这两个必须为浅色与深色分别调校。
public enum Theme {
    public static let interfaceFont = Font.system(size: 13)
    public static let codeFont = Font.system(size: 12, design: .monospaced)

    /// NSTextView 需要 NSFont 而不是 SwiftUI 的 Font。
    public static let codeNSFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    public static let additionBackground = Color("DiffAddition", bundle: .module)
    public static let deletionBackground = Color("DiffDeletion", bundle: .module)
    public static let additionGutter = Color("DiffAdditionGutter", bundle: .module)
    public static let deletionGutter = Color("DiffDeletionGutter", bundle: .module)

    /// 行高。行号槽与代码行必须用同一个值，否则两栏会错位。
    public static let codeLineHeight: CGFloat = 17
}
```

在 `Sources/SiftUI/` 下创建 `Resources/Colors.xcassets`，添加四个 Color Set，每个都设置 Any Appearance 与 Dark 两套值：

| 名称 | 浅色 | 深色 |
|---|---|---|
| DiffAddition | `#E6FFEC` | `#0D2F1A` |
| DiffDeletion | `#FFEBE9` | `#3A1417` |
| DiffAdditionGutter | `#CCFFD8` | `#1B4721` |
| DiffDeletionGutter | `#FFD7D5` | `#5A1E22` |

在 `Package.swift` 的 `SiftUI` target 中声明资源：

```swift
.target(name: "SiftUI",
        dependencies: ["GitKit", "DiffEngine", "RepoStore"],
        resources: [.process("Resources")]),
```

- [ ] **Step 4: 写左栏**

`Sources/SiftUI/SourceSidebar.swift`：

```swift
import SwiftUI
import GitKit
import RepoStore

public extension Notification.Name {
    static let siftAddRepository = Notification.Name("app.sift.addRepository")
}

struct SourceSidebar: View {
    @Environment(RepoStore.self) private var store

    var body: some View {
        List(selection: selectionBinding) {
            ForEach(store.repositories) { repository in
                Section {
                    ForEach(repository.worktrees) { worktree in
                        WorktreeRow(worktree: worktree,
                                    changeCount: changeCount(for: worktree))
                            .tag(worktree.path)
                    }
                } header: {
                    HStack {
                        Text(repository.name)
                        Spacer()
                        // 移除按钮必须鼠标可达，不能只有右键菜单。
                        Button {
                            store.removeRepository(root: repository.root)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("移除此仓库")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                presentOpenPanel()
            } label: {
                Label("添加仓库", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .onReceive(NotificationCenter.default.publisher(for: .siftAddRepository)) { _ in
            presentOpenPanel()
        }
    }

    private var selectionBinding: Binding<URL?> {
        Binding(
            get: { store.selectedWorktree?.path },
            set: { newValue in
                guard let newValue,
                      let worktree = store.repositories
                        .flatMap(\.worktrees).first(where: { $0.path == newValue })
                else { return }
                Task { await store.select(worktree: worktree) }
            })
    }

    /// v1 只为当前选中的 worktree 计算改动数。为所有 worktree 都算需要
    /// 给每个都跑一次 status，那是后台预取的活，等有了真实使用数据再做。
    private func changeCount(for worktree: Worktree) -> Int? {
        guard store.selectedWorktree == worktree else { return nil }
        return store.fileStatuses.count
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "添加"
        panel.message = "选择一个 Git 仓库目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await store.addRepository(at: url) }
    }
}

private struct WorktreeRow: View {
    let worktree: Worktree
    let changeCount: Int?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: worktree.isMain ? "folder" : "arrow.triangle.branch")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(worktree.displayName)
                    .lineLimit(1)
                if !worktree.isMain {
                    Text(worktree.path.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let changeCount, changeCount > 0 {
                Text("\(changeCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.vertical, 2)
    }
}
```

- [ ] **Step 5: 写中栏**

`Sources/SiftUI/FileListPane.swift`：

```swift
import SwiftUI
import GitKit
import DiffEngine
import RepoStore

struct FileListPane: View {
    @Environment(RepoStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            List {
                group(title: "已暂存", statuses: store.fileStatuses.filter(\.hasStagedChanges), staged: true)
                group(title: "未暂存", statuses: store.fileStatuses.filter(\.hasUnstagedChanges), staged: false)
                group(title: "未跟踪", statuses: store.fileStatuses.filter(\.isUntracked), staged: false)
            }
            .listStyle(.inset)
            .overlay {
                if store.fileStatuses.isEmpty && !store.isLoadingFileList {
                    ContentUnavailableView("没有改动", systemImage: "checkmark.circle")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("", selection: $store.usesTreeView) {
                    Image(systemName: "list.bullet").tag(false)
                    Image(systemName: "list.bullet.indent").tag(true)
                }
                .pickerStyle(.segmented)
                .help("切换平铺视图与树视图")
            }
        }
    }

    @ViewBuilder
    private func group(title: String, statuses: [FileStatus], staged: Bool) -> some View {
        if !statuses.isEmpty {
            Section(title) {
                if store.usesTreeView {
                    let nodes = FileTreeBuilder.build(
                        from: statuses, collapsingSingleChildDirectories: true)
                    ForEach(nodes) { node in
                        treeNode(node, staged: staged)
                    }
                } else {
                    ForEach(statuses) { status in
                        fileRow(status, staged: staged, showsFullPath: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func treeNode(_ node: FileTreeNode, staged: Bool) -> some View {
        switch node {
        case .file(let status):
            fileRow(status, staged: staged, showsFullPath: false)
        case .directory(let name, _, let children):
            DisclosureGroup {
                ForEach(children) { child in treeNode(child, staged: staged) }
            } label: {
                Label(name, systemImage: "folder")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func fileRow(_ status: FileStatus, staged: Bool, showsFullPath: Bool) -> some View {
        let isSelected = store.selectedFile?.path == status.path
            && store.selectedFileIsStaged == staged
        return HStack(spacing: 6) {
            StatusBadge(kind: staged ? status.indexStatus : status.worktreeStatus)
            Text(showsFullPath ? status.path : status.fileName)
                .font(Theme.interfaceFont)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            if let stats = store.lineStats[status.path] {
                LineStatsBadge(stats: stats)
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.15) : .clear)
        .onTapGesture {
            Task { await store.select(file: status, staged: staged) }
        }
    }
}

private struct LineStatsBadge: View {
    let stats: LineStats

    var body: some View {
        if stats.isBinary {
            Text("二进制")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 4) {
                if stats.added > 0 {
                    Text("+\(stats.added)")
                        .foregroundStyle(.green)
                }
                if stats.deleted > 0 {
                    Text("−\(stats.deleted)")
                        .foregroundStyle(.red)
                }
            }
            .font(.caption.monospacedDigit())
        }
    }
}

private struct StatusBadge: View {
    let kind: FileChangeKind

    var body: some View {
        Text(letter)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 14)
    }

    private var letter: String {
        switch kind {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        case .unmerged: "U"
        case .untracked: "?"
        case .unmodified: " "
        }
    }

    private var color: Color {
        switch kind {
        case .added, .untracked: .green
        case .deleted: .red
        case .renamed, .copied: .purple
        case .unmerged: .orange
        default: .accentColor
        }
    }
}
```

- [ ] **Step 6: 写三栏容器**

`Sources/SiftUI/ContentView.swift`：

```swift
import SwiftUI
import RepoStore

public struct ContentView: View {
    @Environment(RepoStore.self) private var store

    public init() {}

    public var body: some View {
        NavigationSplitView {
            SourceSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } content: {
            FileListPane()
                .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 480)
        } detail: {
            // Task 13 会把这里换成真正的 diff 视图。
            Text("选择一个文件")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("出错了",
               isPresented: .constant(store.errorMessage != nil),
               presenting: store.errorMessage) { _ in
            Button("好") { store.errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }
}
```

- [ ] **Step 7: 手动验证**

在 Xcode 中运行应用，依次确认：

1. 窗口打开，显示三栏。
2. 点"添加仓库"，选一个真实的 git 仓库，它出现在左栏，下面挂着 `main` 工作树。
3. 在该仓库里手动改一个文件（用编辑器或 `echo x >> somefile`），**不做任何操作**，中栏在一秒内自动出现该文件。这验证了 FSEvents 链路。
4. 给该仓库 `git worktree add ../wt-test -b test`，左栏在刷新后出现第二个工作树，缩进在同一个仓库下。
5. 点击不同工作树，中栏内容随之切换。
6. 切换平铺/树视图，中栏布局改变。
7. 每个已跟踪文件行的右端显示 `+N −M` 行数，颜色分别为绿色和红色；未跟踪文件不显示行数。
8. 关闭应用再打开，之前添加的仓库还在。
9. 应用空闲时打开活动监视器，Sift 的 CPU 占用应稳定为 0.0%。**这一条不过就不能进入下一个任务。**

- [ ] **Step 8: 提交**

```bash
git rm -f Sources/SiftUI/Placeholder.swift 2>/dev/null || true
git add App Sources/SiftUI Package.swift
git commit -m "feat(SiftUI): 应用壳与三栏界面"
```

---

### Task 13: diff 渲染

**Files:**
- Create: `Sources/SiftUI/DiffDocumentBuilder.swift`
- Create: `Sources/SiftUI/DiffTextView.swift`
- Create: `Sources/SiftUI/DiffPane.swift`
- Create: `Tests/DiffEngineTests/DiffDocumentBuilderTests.swift`
- Modify: `Sources/SiftUI/ContentView.swift`（把 detail 栏的占位文字换成 `DiffPane`）
- Modify: `Package.swift`（给 `DiffEngineTests` 加上 `SiftUI` 依赖）

**Interfaces:**
- Consumes: Task 5 的 `FileDiff` / `Hunk` / `DiffLine`，Task 8 的 `LoadedDiff`，Task 10 的 `RepoStore`，Task 12 的 `Theme`。
- Produces: `DiffDocumentBuilder` 枚举，静态方法 `build(_ diff: FileDiff, layout: DiffLayout) -> NSAttributedString`；`DiffLayout` 枚举（`.unified`、`.split`）；`DiffTextView` 结构体（`NSViewRepresentable`，`init(document: NSAttributedString)`）；`DiffPane` 视图。

**说明：** v1 只实现 `.unified`。`.split` 是计划二的内容，但 `DiffLayout` 参数现在就加上，避免之后改签名。文本文档按"一个长文档"的模型构建，为计划二的连续滚动模式留好路。

- [ ] **Step 1: 写失败的测试**

`Tests/DiffEngineTests/DiffDocumentBuilderTests.swift`：

```swift
import XCTest
import GitKit
@testable import SiftUI

final class DiffDocumentBuilderTests: XCTestCase {
    private func makeDiff(_ lines: [DiffLine], oldStart: Int = 1, newStart: Int = 1) -> FileDiff {
        let hunk = Hunk(oldStart: oldStart, oldCount: lines.count,
                        newStart: newStart, newCount: lines.count,
                        sectionHeading: "func example()", lines: lines)
        return FileDiff(path: "a.swift", originalPath: nil, content: .textual([hunk]))
    }

    func testRendersAllLines() {
        let diff = makeDiff([
            DiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "keep"),
            DiffLine(kind: .deletion, oldLineNumber: 2, newLineNumber: nil, text: "gone"),
            DiffLine(kind: .addition, oldLineNumber: nil, newLineNumber: 2, text: "fresh"),
        ])
        let document = DiffDocumentBuilder.build(diff, layout: .unified)
        let text = document.string
        XCTAssertTrue(text.contains("keep"))
        XCTAssertTrue(text.contains("gone"))
        XCTAssertTrue(text.contains("fresh"))
    }

    func testIncludesHunkHeading() {
        let diff = makeDiff([
            DiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "keep"),
        ])
        XCTAssertTrue(DiffDocumentBuilder.build(diff, layout: .unified).string
            .contains("func example()"))
    }

    func testAdditionLineCarriesAdditionBackground() {
        let diff = makeDiff([
            DiffLine(kind: .addition, oldLineNumber: nil, newLineNumber: 1, text: "fresh"),
        ])
        let document = DiffDocumentBuilder.build(diff, layout: .unified)
        let range = (document.string as NSString).range(of: "fresh")
        let attributes = document.attributes(at: range.location, effectiveRange: nil)
        XCTAssertNotNil(attributes[.backgroundColor], "新增行必须有背景色")
    }

    func testUsesMonospacedFontThroughout() {
        let diff = makeDiff([
            DiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "keep"),
        ])
        let document = DiffDocumentBuilder.build(diff, layout: .unified)
        let font = document.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        XCTAssertTrue(font!.isFixedPitch, "代码必须用等宽字体")
    }

    func testLineNumbersAppearInGutter() {
        let diff = makeDiff([
            DiffLine(kind: .context, oldLineNumber: 42, newLineNumber: 43, text: "keep"),
        ], oldStart: 42, newStart: 43)
        let text = DiffDocumentBuilder.build(diff, layout: .unified).string
        XCTAssertTrue(text.contains("42"))
        XCTAssertTrue(text.contains("43"))
    }

    func testEmptyDiffProducesEmptyDocument() {
        let diff = FileDiff(path: "a.swift", originalPath: nil, content: .empty)
        XCTAssertEqual(DiffDocumentBuilder.build(diff, layout: .unified).length, 0)
    }

    /// 性能护栏：大 diff 的文档构建必须够快，不然点开文件那 100ms 预算就爆了。
    func testBuildsLargeDocumentQuickly() {
        let lines = (0..<10_000).map { index in
            DiffLine(kind: index % 3 == 0 ? .addition : .context,
                     oldLineNumber: index, newLineNumber: index,
                     text: "some source code line number \(index)")
        }
        let diff = makeDiff(lines)
        let start = ContinuousClock.now
        _ = DiffDocumentBuilder.build(diff, layout: .unified)
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .milliseconds(50),
                          "10000 行的文档构建耗时 \(elapsed)，超出预算")
    }
}
```

- [ ] **Step 2: 给测试 target 加依赖并跑测试确认失败**

在 `Package.swift` 中把 `DiffEngineTests` 改为：

```swift
.testTarget(name: "DiffEngineTests", dependencies: ["DiffEngine", "SiftUI"]),
```

Run: `swift test --filter DiffDocumentBuilderTests`
Expected: 编译失败，报 `cannot find 'DiffDocumentBuilder' in scope`。

- [ ] **Step 3: 实现文档构建器**

`Sources/SiftUI/DiffDocumentBuilder.swift`：

```swift
import AppKit
import GitKit

public enum DiffLayout: Sendable {
    case unified
    /// 计划二实现。
    case split
}

/// 把 FileDiff 转成一个可直接交给 NSTextView 的 NSAttributedString。
///
/// 纯函数，没有 UI 依赖，因此可以完整测试，也可以放到主线程之外去跑。
///
/// 行号写进文本本身（而不是画在单独的视图里），这样选中和复制会自然工作，
/// 也不需要维护第二个视图跟主文本滚动同步。代价是复制出来会带行号，
/// 计划二会加一个"复制时剔除行号"的处理。
public enum DiffDocumentBuilder {
    private static let gutterWidth = 4

    public static func build(_ diff: FileDiff, layout: DiffLayout) -> NSAttributedString {
        guard case .textual(let hunks) = diff.content, !hunks.isEmpty else {
            return NSAttributedString()
        }

        let document = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = Theme.codeLineHeight
        paragraph.maximumLineHeight = Theme.codeLineHeight
        // 代码不换行；横向滚动比自动折行更容易读懂 diff。
        paragraph.lineBreakMode = .byClipping

        for (index, hunk) in hunks.enumerated() {
            if index > 0 { document.append(NSAttributedString(string: "\n")) }
            document.append(headerLine(for: hunk, paragraph: paragraph))
            for line in hunk.lines {
                document.append(bodyLine(line, paragraph: paragraph))
            }
        }
        return document
    }

    private static func headerLine(for hunk: Hunk,
                                   paragraph: NSParagraphStyle) -> NSAttributedString {
        let heading = hunk.sectionHeading.isEmpty ? "" : "  \(hunk.sectionHeading)"
        let text = "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@\(heading)\n"
        return NSAttributedString(string: text, attributes: [
            .font: Theme.codeNSFont,
            .foregroundColor: NSColor.secondaryLabelColor,
            .backgroundColor: NSColor.quaternarySystemFill,
            .paragraphStyle: paragraph,
        ])
    }

    private static func bodyLine(_ line: DiffLine,
                                 paragraph: NSParagraphStyle) -> NSAttributedString {
        if line.kind == .noNewlineMarker {
            return NSAttributedString(string: "\\ 文件末尾没有换行符\n", attributes: [
                .font: Theme.codeNSFont,
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: paragraph,
            ])
        }

        let oldNumber = line.oldLineNumber.map(String.init) ?? ""
        let newNumber = line.newLineNumber.map(String.init) ?? ""
        let gutter = pad(oldNumber) + " " + pad(newNumber) + " "

        let marker: String
        switch line.kind {
        case .addition: marker = "+"
        case .deletion: marker = "-"
        default: marker = " "
        }

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: gutter, attributes: [
            .font: Theme.codeNSFont,
            .foregroundColor: NSColor.tertiaryLabelColor,
            .backgroundColor: gutterColor(for: line.kind),
            .paragraphStyle: paragraph,
        ]))
        result.append(NSAttributedString(string: "\(marker)\(line.text)\n", attributes: [
            .font: Theme.codeNSFont,
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: bodyColor(for: line.kind),
            .paragraphStyle: paragraph,
        ]))
        return result
    }

    private static func pad(_ text: String) -> String {
        text.count >= gutterWidth
            ? text
            : String(repeating: " ", count: gutterWidth - text.count) + text
    }

    private static func bodyColor(for kind: DiffLineKind) -> NSColor {
        switch kind {
        case .addition: NSColor(named: "DiffAddition", bundle: .module) ?? .clear
        case .deletion: NSColor(named: "DiffDeletion", bundle: .module) ?? .clear
        default: .clear
        }
    }

    private static func gutterColor(for kind: DiffLineKind) -> NSColor {
        switch kind {
        case .addition: NSColor(named: "DiffAdditionGutter", bundle: .module) ?? .clear
        case .deletion: NSColor(named: "DiffDeletionGutter", bundle: .module) ?? .clear
        default: .clear
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter DiffDocumentBuilderTests`
Expected: 7 个测试全部通过，包括那个 50ms 的性能护栏。

- [ ] **Step 5: 实现 NSTextView 封装**

`Sources/SiftUI/DiffTextView.swift`：

```swift
import SwiftUI
import AppKit

/// NSTextView 的 SwiftUI 封装。
///
/// 为什么不用 SwiftUI 的 Text：SwiftUI 没有能处理上万行文档的文本视图。
/// NSTextView 给的是二十年优化过的文本布局、原生选中、无障碍和滚动惯性。
///
/// 关键性能约定：更新文档时用 `replaceCharacters` 整体替换，
/// 并且**绝不**在滚动过程中改动 text storage。计划二的语法高亮必须走
/// attribute-only 的覆盖路径，不能重建文档，否则滚动位置会跳。
struct DiffTextView: NSViewRepresentable {
    let document: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        // 不换行：宽度设为无限，靠横向滚动。
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              let storage = textView.textStorage else { return }
        // 内容没变就什么都不做，避免 SwiftUI 每次重绘都重建文档。
        guard storage.string != document.string else { return }
        storage.beginEditing()
        storage.setAttributedString(document)
        storage.endEditing()
        textView.scroll(NSPoint(x: 0, y: 0))
    }
}
```

- [ ] **Step 6: 实现右栏容器**

`Sources/SiftUI/DiffPane.swift`：

```swift
import SwiftUI
import GitKit
import DiffEngine
import RepoStore

struct DiffPane: View {
    @Environment(RepoStore.self) private var store

    var body: some View {
        Group {
            switch store.loadedDiff {
            case .none:
                if store.selectedFile == nil {
                    ContentUnavailableView("选择一个文件", systemImage: "doc.text")
                } else {
                    ProgressView().controlSize(.small)
                }
            case .ready(let diff):
                switch diff.content {
                case .empty:
                    ContentUnavailableView("此文件没有文本差异", systemImage: "equal.circle")
                case .binary:
                    ContentUnavailableView("二进制文件", systemImage: "doc.badge.gearshape")
                case .modeChangeOnly(let oldMode, let newMode):
                    ContentUnavailableView {
                        Label("只有文件权限变化", systemImage: "lock.rotation")
                    } description: {
                        Text("\(oldMode) → \(newMode)")
                            .font(Theme.codeFont)
                    }
                case .textual:
                    DiffTextView(document: DiffDocumentBuilder.build(diff, layout: .unified))
                }
            case .collapsed(let reason, let path):
                CollapsedFileView(path: path, reason: reason) {
                    Task { await store.expandCollapsedDiff() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(store.selectedFile?.path ?? "")
    }
}

private struct CollapsedFileView: View {
    let path: String
    let reason: GeneratedFileReason
    let onExpand: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.zipper")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(path)
                .font(Theme.codeFont)
                .lineLimit(1)
                .truncationMode(.head)
            Text("这是生成文件或体积过大的文件（\(reason.explanation)），已默认折叠。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("仍要查看", action: onExpand)
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: 420)
    }
}
```

- [ ] **Step 7: 接到 ContentView**

把 `Sources/SiftUI/ContentView.swift` 中 detail 栏的占位内容替换掉：

```swift
        } detail: {
            DiffPane()
        }
```

同时删掉那三行占位的 `Text("选择一个文件")` 及其修饰符。

- [ ] **Step 8: 手动验证**

在 Xcode 中运行，确认：

1. 点击一个改动文件，右栏显示 diff，增删行有颜色区分，行号在左侧对齐。
2. 打开一个有几千行改动的文件，滚动流畅不掉帧。
3. 点击一个 lockfile，右栏显示折叠占位条，点"仍要查看"后加载出真实内容。
4. 点击一个未跟踪文件，整个文件显示为新增。
5. 用鼠标拖选几行代码，能正常选中并 `⌘C` 复制。
6. 切换系统的浅色/深色外观，增删色在两种模式下都清晰可读。
7. 在系统设置中打开"增强对比度"，diff 颜色仍能分辨。

- [ ] **Step 9: 提交**

```bash
git add Sources/SiftUI Tests/DiffEngineTests/DiffDocumentBuilderTests.swift Package.swift
git commit -m "feat(SiftUI): diff 渲染"
```

---

### Task 14: 性能门禁

**Files:**
- Create: `Scripts/make-large-fixture.sh`
- Create: `Scripts/preflight.sh`
- Create: `Tests/PerformanceTests/LargeRepoPerformanceTests.swift`
- Delete: `Tests/PerformanceTests/Placeholder.swift`

**Interfaces:**
- Consumes: Task 6 的 `GitRepository`、Task 8 的 `DiffEngine`、Task 9 的 `FileTreeBuilder`。
- Produces: `Scripts/preflight.sh`，退出码 0 表示构建、测试、性能门禁全部通过。

- [ ] **Step 1: 写大仓库生成脚本**

`Scripts/make-large-fixture.sh`：

```bash
#!/usr/bin/env bash
# 生成一个有 1000 个改动文件的仓库，用于性能测试。
# 用法：make-large-fixture.sh <目标目录>
set -euo pipefail

TARGET="${1:?用法: make-large-fixture.sh <目标目录>}"
FILE_COUNT=1000
LINES_PER_FILE=200

rm -rf "$TARGET"
mkdir -p "$TARGET"
cd "$TARGET"

git init -q -b main
git config user.email "perf@sift.local"
git config user.name "Sift Perf"
git config commit.gpgsign false

for i in $(seq 1 "$FILE_COUNT"); do
  dir="src/module$((i % 20))/sub$((i % 7))"
  mkdir -p "$dir"
  seq 1 "$LINES_PER_FILE" | sed "s/^/line /" > "$dir/file$i.ts"
done

# 再放一个大文件，验证折叠规则确实拦住了它。
seq 1 50000 | sed 's/^/generated line /' > pnpm-lock.yaml

git add -A
git commit -q -m "baseline"

# 每个文件改一行，制造 1000 个改动文件。
for i in $(seq 1 "$FILE_COUNT"); do
  dir="src/module$((i % 20))/sub$((i % 7))"
  sed -i '' '100s/.*/line 100 MODIFIED/' "$dir/file$i.ts"
done

echo "已在 $TARGET 生成 $FILE_COUNT 个改动文件"
```

Run: `chmod +x Scripts/make-large-fixture.sh`

- [ ] **Step 2: 写性能测试**

`Tests/PerformanceTests/LargeRepoPerformanceTests.swift`：

```swift
import XCTest
import GitKit
import DiffEngine

/// 性能是本项目的最高优先级，这些测试是它的守卫。
/// 用显式的耗时断言而不是 XCTest 的 measure baseline，因为 baseline
/// 需要人工录制、在 CI 上不可靠，而我们要的是"超了就挂"的硬门禁。
final class LargeRepoPerformanceTests: XCTestCase {
    private static var repositoryURL: URL!

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

        guard case .collapsed = loaded else {
            return XCTFail("50000 行的 lockfile 必须被折叠，实际是 \(loaded)")
        }
        XCTAssertLessThan(elapsed, .milliseconds(10),
                          "折叠判断不应读取文件内容，耗时 \(elapsed)")
    }
}
```

- [ ] **Step 3: 跑性能测试**

Run: `swift test --filter LargeRepoPerformanceTests`
Expected: 4 个测试全部通过。

如果某项超时，**不要放宽阈值**——阈值来自设计文档的硬指标。去找真正的原因：是不是多跑了一次 git、是不是缓存没命中、是不是在做不必要的字符串拷贝。

- [ ] **Step 4: 写门禁脚本**

`Scripts/preflight.sh`：

```bash
#!/usr/bin/env bash
# 构建、测试、性能门禁。CI 与本地提交前都跑这个。
# 任何一项失败都以非零退出码结束。
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> 构建"
swift build

echo "==> 单元测试"
swift test --skip PerformanceTests

echo "==> 性能门禁"
swift test --filter LargeRepoPerformanceTests

echo "==> 全部通过"
```

Run: `chmod +x Scripts/preflight.sh && ./Scripts/preflight.sh`
Expected: 以 `==> 全部通过` 结束，退出码 0。

- [ ] **Step 5: 提交**

```bash
git rm -f Tests/PerformanceTests/Placeholder.swift 2>/dev/null || true
git add Scripts Tests/PerformanceTests
git commit -m "feat: 性能门禁与大仓库 fixture"
```

- [ ] **Step 6: 最终验收**

对照设计文档第 4 节逐项确认：

1. **冷启动 < 300ms** —— 在 Xcode 中用 Instruments 的 App Launch 模板测，或者简单地在 `SiftApp` 里记录从 `main` 到首帧的时间。
2. **切换仓库 < 150ms** —— 已由 `testStatusOnThousandChangedFilesUnder150ms` 覆盖。
3. **开文件 < 100ms** —— 已由 `testSingleFileDiffUnder100ms` 覆盖。
4. **滚动不掉帧** —— 打开一个几千行的 diff，用 Instruments 的 Animation Hitches 模板滚动 10 秒，确认无掉帧。
5. **空闲 CPU 恒为 0%** —— 挂 5 个仓库，应用置于后台 5 分钟，活动监视器中 CPU 应稳定为 0.0%。
6. **内存 < 150MB** —— 挂 5 个仓库、依次点开 20 个文件后，在活动监视器中查看常驻内存。

任何一项不达标，都记录具体数字后回头优化，不要放宽指标。

---

## 计划完成后的状态

一个可运行的原生 macOS 应用，能够：添加多个 Git 仓库并持久化；自动发现并在侧边栏中按层级展示每个仓库的 worktree；实时（通过 FSEvents，无轮询）显示当前 worktree 的改动文件；平铺或树视图切换；点击文件查看统一视图 diff；自动折叠生成文件与超大文件。全部性能指标有自动化测试守卫。

**尚未实现（计划二）：** hunk 级 stage/discard、语法高亮、AI 解释面板、分栏 diff 视图、blame 侧槽、连续滚动模式、设置界面。
