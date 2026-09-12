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
