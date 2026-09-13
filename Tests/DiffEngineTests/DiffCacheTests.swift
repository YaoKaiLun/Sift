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

    func testRemovePathClearsBothSidesAndLeavesOthers() async {
        let cache = DiffCache()
        let wt = URL(fileURLWithPath: "/w")
        await cache.insert(diff("a.txt"), for: DiffCacheKey(worktreePath: wt, filePath: "a.txt", staged: false))
        await cache.insert(diff("a.txt"), for: DiffCacheKey(worktreePath: wt, filePath: "a.txt", staged: true))
        await cache.insert(diff("b.txt"), for: DiffCacheKey(worktreePath: wt, filePath: "b.txt", staged: false))
        await cache.remove(inWorktree: wt, filePath: "a.txt")
        let unstagedA = await cache.value(for: DiffCacheKey(worktreePath: wt, filePath: "a.txt", staged: false))
        let stagedA = await cache.value(for: DiffCacheKey(worktreePath: wt, filePath: "a.txt", staged: true))
        let unstagedB = await cache.value(for: DiffCacheKey(worktreePath: wt, filePath: "b.txt", staged: false))
        XCTAssertNil(unstagedA)
        XCTAssertNil(stagedA)
        XCTAssertNotNil(unstagedB)
    }
}
