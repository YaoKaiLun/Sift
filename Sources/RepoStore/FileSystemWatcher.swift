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
