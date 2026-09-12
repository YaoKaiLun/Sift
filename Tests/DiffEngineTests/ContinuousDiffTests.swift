import XCTest
import AppKit
import GitKit
@testable import DiffEngine
@testable import SiftUI

/// 假 DiffEngine：只计数 load 调用。占位计划构建不得触发它。
private final class CountingDiffEngine: @unchecked Sendable {
    private(set) var loadCount = 0

    func load(status: FileStatus, staged: Bool) {
        loadCount += 1
    }
}

final class ContinuousDiffTests: XCTestCase {
    private func staged(_ path: String) -> FileStatus {
        FileStatus(path: path, originalPath: nil,
                   indexStatus: .modified, worktreeStatus: .unmodified)
    }

    private func unstaged(_ path: String) -> FileStatus {
        FileStatus(path: path, originalPath: nil,
                   indexStatus: .unmodified, worktreeStatus: .modified)
    }

    private func bothSides(_ path: String) -> FileStatus {
        FileStatus(path: path, originalPath: nil,
                   indexStatus: .modified, worktreeStatus: .modified)
    }

    private func untracked(_ path: String) -> FileStatus {
        FileStatus(path: path, originalPath: nil,
                   indexStatus: .untracked, worktreeStatus: .untracked)
    }

    func testBuildOrdersStagedThenUnstagedThenUntracked() {
        let statuses = [
            untracked("z-new.txt"),
            unstaged("b-unstaged.swift"),
            staged("a-staged.swift"),
        ]
        let plan = ContinuousDiffPlan.build(
            statuses: statuses,
            stagedStats: [:],
            unstagedStats: [:])

        XCTAssertEqual(plan.map(\.id), [
            "s:a-staged.swift",
            "u:b-unstaged.swift",
            "u:z-new.txt",
        ])
        XCTAssertEqual(plan.map(\.staged), [true, false, false])
        XCTAssertEqual(plan.map(\.status.path), [
            "a-staged.swift",
            "b-unstaged.swift",
            "z-new.txt",
        ])
    }

    func testFileInBothSidesAppearsTwice() {
        let statuses = [bothSides("shared.swift"), unstaged("only-worktree.swift")]
        let plan = ContinuousDiffPlan.build(
            statuses: statuses,
            stagedStats: ["shared.swift": LineStats(added: 1, deleted: 0, isBinary: false)],
            unstagedStats: [
                "shared.swift": LineStats(added: 2, deleted: 3, isBinary: false),
                "only-worktree.swift": LineStats(added: 4, deleted: 0, isBinary: false),
            ])

        XCTAssertEqual(plan.map(\.id), [
            "s:shared.swift",
            "u:shared.swift",
            "u:only-worktree.swift",
        ])
        XCTAssertEqual(plan[0].headerTitle, "shared.swift  +1")
        XCTAssertEqual(plan[1].headerTitle, "shared.swift  +2 −3")
        XCTAssertEqual(plan[2].headerTitle, "only-worktree.swift  +4")
    }

    func testHeaderOmitsNumbersWhenStatsMissing() {
        let plan = ContinuousDiffPlan.build(
            statuses: [unstaged("mystery.swift")],
            stagedStats: [:],
            unstagedStats: [:])

        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].headerTitle, "mystery.swift")
        XCTAssertNil(plan[0].added)
        XCTAssertNil(plan[0].deleted)
    }

    func testBuildDoesNotLoadDiffs() {
        let loader = CountingDiffEngine()
        let statuses = [
            staged("a.swift"),
            unstaged("b.swift"),
            untracked("c.swift"),
        ]
        let plan = ContinuousDiffPlan.build(
            statuses: statuses,
            stagedStats: ["a.swift": LineStats(added: 1, deleted: 1, isBinary: false)],
            unstagedStats: ["b.swift": LineStats(added: 2, deleted: 0, isBinary: false)])

        XCTAssertEqual(plan.count, 3)
        XCTAssertEqual(loader.loadCount, 0, "构建占位计划时不得调用 DiffEngine.load")
    }

    func testVisibleRangeSelectsIntersectingPlaceholdersOnly() {
        let plan = ContinuousDiffPlan.build(
            statuses: [staged("a.swift"), staged("b.swift"), staged("c.swift")],
            stagedStats: [:],
            unstagedStats: [:])
        let ranges: [String: NSRange] = [
            "s:a.swift": NSRange(location: 0, length: 10),
            "s:b.swift": NSRange(location: 10, length: 10),
            "s:c.swift": NSRange(location: 20, length: 10),
        ]

        let visible = ContinuousDiffPlan.entriesNeedingLoad(
            plan,
            ranges: ranges,
            visibleRange: NSRange(location: 8, length: 6),
            alreadyLoaded: [])

        XCTAssertEqual(visible.map(\.id), ["s:a.swift", "s:b.swift"])
    }

    func testAlreadyLoadedEntriesAreNotReturned() {
        let plan = ContinuousDiffPlan.build(
            statuses: [staged("a.swift"), staged("b.swift")],
            stagedStats: [:],
            unstagedStats: [:])
        let ranges: [String: NSRange] = [
            "s:a.swift": NSRange(location: 0, length: 10),
            "s:b.swift": NSRange(location: 10, length: 10),
        ]

        let visible = ContinuousDiffPlan.entriesNeedingLoad(
            plan,
            ranges: ranges,
            visibleRange: NSRange(location: 0, length: 20),
            alreadyLoaded: ["s:a.swift"])

        XCTAssertEqual(visible.map(\.id), ["s:b.swift"])
    }

    func testPlaceholderHeaderUsesSiftRoleHeader() {
        let entry = ContinuousDiffEntry(
            status: unstaged("src/a.swift"), staged: false, added: 3, deleted: 1)
        let document = DiffDocumentBuilder.buildContinuous(
            sections: [(entry, nil)], layout: .unified)

        XCTAssertTrue(document.text.string.hasPrefix("src/a.swift  +3 −1"))
        let role = document.text.attribute(.siftRole, at: 0, effectiveRange: nil) as? String
        XCTAssertEqual(role, "header")
        XCTAssertEqual(document.fileHeaders.count, 1)
        XCTAssertEqual(document.fileHeaders[0].id, "u:src/a.swift")
        XCTAssertTrue(document.fileHeaders[0].isPlaceholder)
    }

    func testContinuousDocumentKeepsUnloadedFilesAsHeaders() {
        let a = ContinuousDiffEntry(
            status: staged("a.swift"), staged: true, added: 1, deleted: 0)
        let b = ContinuousDiffEntry(
            status: unstaged("b.swift"), staged: false, added: 2, deleted: 0)
        let hunk = Hunk(
            oldStart: 1, oldCount: 1, newStart: 1, newCount: 1,
            sectionHeading: "",
            lines: [DiffLine(kind: .addition, oldLineNumber: nil, newLineNumber: 1, text: "fresh")])
        let loaded = LoadedDiff.ready(
            FileDiff(path: "a.swift", originalPath: nil, content: .textual([hunk])))

        let document = DiffDocumentBuilder.buildContinuous(
            sections: [(a, loaded), (b, nil)], layout: .unified)

        XCTAssertTrue(document.text.string.contains("a.swift  +1"))
        XCTAssertTrue(document.text.string.contains("fresh"))
        XCTAssertTrue(document.text.string.contains("b.swift  +2"))
        XCTAssertEqual(document.fileHeaders.map(\.isPlaceholder), [false, true])
        XCTAssertEqual(document.hunkHeaders.count, 1)
        XCTAssertTrue(document.hunkHeaders[0].id.hasPrefix("s:a.swift:"))
    }

    func testCollapsedSectionStaysCollapsedUntilForced() {
        let entry = ContinuousDiffEntry(
            status: unstaged("package-lock.json"), staged: false, added: 1, deleted: 0)
        let loaded = LoadedDiff.collapsed(reason: .pathRule("*-lock.json"), path: "package-lock.json")
        let document = DiffDocumentBuilder.buildContinuous(
            sections: [(entry, loaded)], layout: .unified)

        XCTAssertTrue(document.text.string.contains("package-lock.json"))
        XCTAssertTrue(document.text.string.contains("已默认折叠"))
        XCTAssertFalse(document.text.string.contains("@@"))
        XCTAssertEqual(document.fileHeaders.count, 1)
        XCTAssertTrue(document.fileHeaders[0].isCollapsed)
        XCTAssertFalse(document.fileHeaders[0].isPlaceholder)
    }
}
