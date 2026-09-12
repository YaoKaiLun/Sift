import Foundation
import CoreServices

/// FSEvents C 回调持有这份状态，而不是 `FileSystemWatcher`。
/// 这样 stream 的 extra retain 不会和 Watcher 形成环，deinit 也不会把 in-flight 回调变成 UAF。
private final class WatcherState: @unchecked Sendable {
    let debounce: Duration
    let onChange: @Sendable () -> Void
    let queue: DispatchQueue
    var pendingWork: DispatchWorkItem?
    let lock = NSLock()
    var stopped = false

    init(debounce: Duration, queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {
        self.debounce = debounce
        self.queue = queue
        self.onChange = onChange
    }

    func stop() {
        lock.lock()
        stopped = true
        pendingWork?.cancel()
        pendingWork = nil
        lock.unlock()
    }

    func scheduleCallback() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        pendingWork?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        pendingWork = work
        lock.unlock()

        let milliseconds = Int(Double(debounce.components.seconds) * 1000
            + Double(debounce.components.attoseconds) / 1e15)
        queue.asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: work)
    }
}

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
    private let state: WatcherState

    public init(path: URL, debounce: Duration = .milliseconds(100),
                onChange: @escaping @Sendable () -> Void) {
        let state = WatcherState(debounce: debounce, queue: queue, onChange: onChange)
        self.state = state

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(state).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let unmanaged = Unmanaged<WatcherState>.fromOpaque(info)
            let state = unmanaged.retain().takeUnretainedValue()
            defer { unmanaged.release() }
            state.lock.lock()
            let stopped = state.stopped
            state.lock.unlock()
            if stopped { return }
            state.scheduleCallback()
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
        state.stop()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        // 对冲 create 时 passRetained 交给 stream 的那一次 extra retain。
        Unmanaged.passUnretained(state).release()
    }
}
