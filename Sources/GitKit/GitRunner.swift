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
