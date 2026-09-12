import Darwin
import Foundation
import os

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
/// 4. 整个进程生命周期必须离开主线程。Swift 6.2 的 `nonisolated async` 会跟调用方
///    执行器，MainActor 一调就会在主线程 `process.run()`。因此用 `Task.detached`
///    跳出主 actor，并在独立 `Thread` 上启动/等待（GCD 线程不跑 RunLoop，
///    Foundation 可能永远收不到子进程退出通知）。
public struct GitRunner: Sendable {
    private let timeout: Duration
    private static let executable = URL(fileURLWithPath: "/usr/bin/git")
    /// SIGTERM 被忽略时，再给进程一小段时间处理，随后升级为 SIGINT / SIGKILL。
    private static let stopGrace = Duration.seconds(1)

    public init(timeout: Duration = .seconds(30)) {
        self.timeout = timeout
    }

    /// 执行 git，非零退出时抛错。
    public func run(
        _ arguments: [String],
        in directory: URL,
        stdin: Data? = nil,
        optionalLocks: Bool = true
    ) async throws -> Data {
        let output = try await runAllowingFailure(
            arguments, in: directory, stdin: stdin, optionalLocks: optionalLocks)
        guard output.exitCode == 0 else {
            throw GitError.nonZeroExit(
                command: arguments.joined(separator: " "),
                exitCode: output.exitCode,
                stderr: output.stderr)
        }
        return output.stdout
    }

    /// 执行 git，非零退出也正常返回，由调用方判断。
    public func runAllowingFailure(
        _ arguments: [String],
        in directory: URL,
        stdin: Data? = nil,
        optionalLocks: Bool = true
    ) async throws -> GitOutput {
        let timeout = self.timeout
        let work = Task.detached(priority: .userInitiated) {
            try await Self.execute(
                arguments: arguments,
                directory: directory,
                timeout: timeout,
                stdin: stdin,
                optionalLocks: optionalLocks)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// 在非主线程上跑完一次 git 子进程。
    private static func execute(
        arguments: [String],
        directory: URL,
        timeout: Duration,
        stdin: Data?,
        optionalLocks: Bool
    ) async throws -> GitOutput {
        try Task.checkCancellation()

        let box = ProcessBox()
        let process = box.process
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        // 禁止 git 弹凭证提示（否则子进程会永远挂着）。
        // 只读操作设置 GIT_OPTIONAL_LOCKS=0，避免抢 index 锁；写操作必须拿 index 锁。
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        if optionalLocks {
            environment["GIT_OPTIONAL_LOCKS"] = "0"
        } else {
            // 必须显式移除：ProcessInfo 会继承父进程的 GIT_OPTIONAL_LOCKS=0，
            // 仅“不设置”无法覆盖，写操作会错误地跳过 index 锁。
            environment.removeValue(forKey: "GIT_OPTIONAL_LOCKS")
        }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe: Pipe?
        if stdin != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
            stdinPipe = nil
        }

        let stop = StopFlag()

        let output: (Data, Data) = try await withTaskCancellationHandler {
            // 启动失败时也必须关闭写端，否则 drain 在 readDataToEndOfFile 上永久阻塞。
            defer {
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
            }

            // 先挂上 drain 与 stdin 写入，再 `run()`。stdin 必须与 stdout/stderr 并发，
            // 写完后关闭写端让 git 看到 EOF；否则大 patch 会堵满 64KB 管道。
            async let out = drain(stdoutPipe)
            async let err = drain(stderrPipe)
            async let written: Void = writeStdin(stdin, to: stdinPipe)

            try await launch(box)

            let timeoutTask = Task.detached(priority: .userInitiated) {
                try await Task.sleep(for: timeout)
                stop.mark(.timeout)
                requestStop(box)
            }
            defer { timeoutTask.cancel() }

            if Task.isCancelled {
                stop.mark(.cancelled)
                requestStop(box)
            }

            let chunks = await (out, err)
            await written
            await waitForExit(box)
            return chunks
        } onCancel: {
            // 必须先标记原因再 terminate，否则退出后只能看到信号，会误报成超时。
            stop.mark(.cancelled)
            requestStop(box)
        }

        if Task.isCancelled || stop.kind == .cancelled {
            throw CancellationError()
        }
        if stop.kind == .timeout {
            throw GitError.timedOut(command: arguments.joined(separator: " "))
        }

        return GitOutput(
            stdout: output.0,
            stderr: String(decoding: output.1, as: UTF8.self),
            exitCode: process.terminationStatus)
    }

    /// 在独立线程上 `run()`，随后同一线程 `waitUntilExit()`，退出后打开闸门。
    private static func launch(_ box: ProcessBox) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Thread.detachNewThread {
                assert(!Thread.isMainThread, "不得在主线程启动 git")
                do {
                    try box.process.run()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: GitError.launchFailed(String(describing: error)))
                    box.notifyExit()
                    return
                }
                assert(!Thread.isMainThread, "不得在主线程 waitUntilExit")
                box.process.waitUntilExit()
                box.notifyExit()
            }
        }
    }

    /// 等启动线程上的 `waitUntilExit()` 结束；自身也必须离开主线程。
    private static func waitForExit(_ box: ProcessBox) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                assert(!Thread.isMainThread, "不得在主线程等待 git 退出")
                box.waitUntilNotified()
                continuation.resume()
            }
        }
    }

    /// SIGTERM → 宽限期 → SIGINT → SIGKILL，保证超时/取消一定能结束。
    private static func requestStop(_ box: ProcessBox) {
        let process = box.process
        guard process.isRunning else { return }
        process.terminate()
        Task.detached(priority: .userInitiated) {
            try? await Task.sleep(for: stopGrace)
            guard process.isRunning else { return }
            process.interrupt()
            guard process.isRunning else { return }
            let pid = process.processIdentifier
            if pid > 0 {
                kill(pid, SIGKILL)
            }
        }
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

    /// 在后台队列上写 stdin。必须用会抛错的 `write(contentsOf:)`，并关掉 SIGPIPE：
    /// `FileHandle.write(_:)` 在 EPIPE 时抛 NSException；未设 `F_SETNOSIGPIPE` 时
    /// 内核会直接 SIGPIPE 把进程打崩。
    private static func writeStdin(_ data: Data?, to pipe: Pipe?) async {
        guard let data, let pipe else { return }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let handle = pipe.fileHandleForWriting
                _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
                do {
                    try handle.write(contentsOf: data)
                    try handle.close()
                } catch {
                    try? handle.close()
                }
                continuation.resume()
            }
        }
    }
}

/// `Process` 不是 Sendable，跨超时/取消任务调用时用此类装箱。
private final class ProcessBox: @unchecked Sendable {
    let process = Process()
    private let exitSema = DispatchSemaphore(value: 0)

    func notifyExit() {
        exitSema.signal()
    }

    func waitUntilNotified() {
        exitSema.wait()
    }
}

/// 超时与取消共用 terminate，必须在发信号之前记下真正原因。
private final class StopFlag: Sendable {
    enum Kind: Sendable {
        case timeout
        case cancelled
    }

    private let lock = OSAllocatedUnfairLock<Kind?>(initialState: nil)

    /// 仅首次标记生效；调用方必须在 `terminate` 之前调用。
    @discardableResult
    func mark(_ kind: Kind) -> Bool {
        lock.withLock { current in
            guard current == nil else { return false }
            current = kind
            return true
        }
    }

    var kind: Kind? {
        lock.withLock { $0 }
    }
}
