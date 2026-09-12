import Foundation

/// 占位实现。Task 11 会换成真正的 FSEvents 版本，接口保持不变。
public final class FileSystemWatcher: @unchecked Sendable {
    public init(path: URL, debounce: Duration = .milliseconds(100),
                onChange: @escaping @Sendable () -> Void) {
        // Task 11 实现。
    }
}
