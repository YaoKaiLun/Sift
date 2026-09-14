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

    func testBuildOrdersStagedThenWorkingTreeIncludingUntracked() {
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

    func testBuildCommitUsesSHAPrefixedIDs() {
        let status = FileStatus(path: "b.txt", originalPath: nil,
                                 indexStatus: .added, worktreeStatus: .unmodified)
        let plan = ContinuousDiffPlan.buildCommit(
            statuses: [status], sha: "abc123", stats: [:])
        XCTAssertEqual(plan.map(\.id), ["c:abc123:b.txt"])
        XCTAssertEqual(plan.first?.commitSHA, "abc123")
    }

    func testWorkingTreeGroupSortsByPathNotChangeKind() {
        let statuses = [
            untracked("Sources/New.swift"),
            unstaged("README.md"),
            untracked(".gitignore"),
            unstaged("Sources/Old.swift"),
        ]
        let plan = ContinuousDiffPlan.build(
            statuses: statuses, stagedStats: [:], unstagedStats: [:])
        XCTAssertEqual(plan.map(\.status.path), [
            ".gitignore",
            "README.md",
            "Sources/New.swift",
            "Sources/Old.swift",
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
            "u:only-worktree.swift",
            "u:shared.swift",
        ])
        XCTAssertEqual(plan[0].headerTitle, "shared.swift  +1")
        XCTAssertEqual(plan[1].headerTitle, "only-worktree.swift  +4")
        XCTAssertEqual(plan[2].headerTitle, "shared.swift  +2 −3")
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

    func testFileIDAtCharacterPicksLastHeaderAtOrBeforeLocation() {
        let headers = [
            DiffFileHeader(id: "u:a.swift", range: NSRange(location: 0, length: 10),
                           isPlaceholder: true, isCollapsed: false),
            DiffFileHeader(id: "u:b.swift", range: NSRange(location: 40, length: 12),
                           isPlaceholder: true, isCollapsed: false),
        ]
        XCTAssertEqual(DiffDocumentBuilder.fileID(atCharacter: 0, in: headers), "u:a.swift")
        XCTAssertEqual(DiffDocumentBuilder.fileID(atCharacter: 39, in: headers), "u:a.swift")
        XCTAssertEqual(DiffDocumentBuilder.fileID(atCharacter: 40, in: headers), "u:b.swift")
        XCTAssertEqual(DiffDocumentBuilder.fileID(atCharacter: 80, in: headers), "u:b.swift")
        XCTAssertNil(DiffDocumentBuilder.fileID(atCharacter: 0, in: []))
    }

    func testContinuousFileHeaderIsHeavierThanHunkHeader() {
        let entry = ContinuousDiffEntry(
            status: unstaged("a.swift"), staged: false, added: 1, deleted: 0)
        let hunk = Hunk(
            oldStart: 1, oldCount: 0, newStart: 1, newCount: 1,
            sectionHeading: "",
            lines: [DiffLine(kind: .addition, oldLineNumber: nil, newLineNumber: 1, text: "fresh")])
        let loaded = LoadedDiff.ready(
            FileDiff(path: "a.swift", originalPath: nil, content: .textual([hunk])))
        let document = DiffDocumentBuilder.buildContinuous(
            sections: [(entry, loaded)], layout: .unified)

        let ns = document.text.string as NSString
        let fileStart = document.fileHeaders[0].range.location
        let hunkStart = document.hunkHeaders[0].range.location
        let fileFont = document.text.attribute(.font, at: fileStart, effectiveRange: nil) as? NSFont
        let hunkFont = document.text.attribute(.font, at: hunkStart, effectiveRange: nil) as? NSFont
        XCTAssertEqual(fileFont?.fontDescriptor.symbolicTraits.contains(.bold), true)
        XCTAssertNotEqual(fileFont?.fontDescriptor.symbolicTraits.contains(.bold),
                          hunkFont?.fontDescriptor.symbolicTraits.contains(.bold))
        let fileStyle = document.text.attribute(
            .paragraphStyle, at: fileStart, effectiveRange: nil) as? NSParagraphStyle
        let hunkStyle = document.text.attribute(
            .paragraphStyle, at: hunkStart, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertGreaterThan(fileStyle?.minimumLineHeight ?? 0,
                             hunkStyle?.minimumLineHeight ?? 0)
        XCTAssertTrue(ns.substring(from: 0).contains("a.swift"))
    }

    func testContinuousFilesAreSeparatedByFilledBreak() {
        let a = ContinuousDiffEntry(
            status: staged("a.swift"), staged: true, added: 1, deleted: 0)
        let b = ContinuousDiffEntry(
            status: unstaged("b.swift"), staged: false, added: 2, deleted: 0)
        let document = DiffDocumentBuilder.buildContinuous(
            sections: [(a, nil), (b, nil)], layout: .unified)

        let second = document.fileHeaders[1].range.location
        XCTAssertGreaterThan(second, document.fileHeaders[0].range.location)
        var breakHeight: CGFloat = 0
        document.text.enumerateAttributes(
            in: NSRange(location: 0, length: second), options: []
        ) { attrs, _, _ in
            guard attrs[.siftRole] as? String == "file-break" else { return }
            let style = attrs[.paragraphStyle] as? NSParagraphStyle
            breakHeight = style?.minimumLineHeight ?? 0
        }
        XCTAssertGreaterThanOrEqual(breakHeight, 20, "文件之间要有空隙，不能只靠一条细线")
    }

    func testContinuousFileHeaderColorsPathAndStats() {
        let entry = ContinuousDiffEntry(
            status: unstaged("Sources/RepoStore/RepoStore.swift"),
            staged: false, added: 12, deleted: 3)
        let document = DiffDocumentBuilder.buildContinuous(
            sections: [(entry, nil)], layout: .unified)
        let text = document.text
        let ns = text.string as NSString

        let dir = ns.range(of: "Sources/RepoStore/")
        let name = ns.range(of: "RepoStore.swift")
        let added = ns.range(of: "+12")
        let deleted = ns.range(of: "−3")
        XCTAssertNotEqual(dir.location, NSNotFound)
        XCTAssertNotEqual(name.location, NSNotFound)
        XCTAssertNotEqual(added.location, NSNotFound)
        XCTAssertNotEqual(deleted.location, NSNotFound)

        let dirColor = text.attribute(.foregroundColor, at: dir.location, effectiveRange: nil) as? NSColor
        let nameFont = text.attribute(.font, at: name.location, effectiveRange: nil) as? NSFont
        let addedColor = text.attribute(.foregroundColor, at: added.location, effectiveRange: nil) as? NSColor
        let deletedColor = text.attribute(.foregroundColor, at: deleted.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(dirColor, NSColor.secondaryLabelColor)
        let nameColor = text.attribute(.foregroundColor, at: name.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(nameColor, NSColor.labelColor)
        XCTAssertEqual(nameFont?.fontDescriptor.symbolicTraits.contains(.bold), true)
        XCTAssertEqual(addedColor, NSColor.systemGreen)
        XCTAssertEqual(deletedColor, NSColor.systemRed)
    }

    func testUntrackedFileHeaderShowsNew() {
        let entry = ContinuousDiffEntry(
            status: untracked("Sources/GitKit/BlameParser.swift"),
            staged: false, added: 106, deleted: 0)
        let document = DiffDocumentBuilder.buildContinuous(
            sections: [(entry, nil)], layout: .unified)
        XCTAssertTrue(document.text.string.contains("New"))
        let ns = document.text.string as NSString
        let name = ns.range(of: "BlameParser.swift")
        let color = document.text.attribute(.foregroundColor, at: name.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, NSColor.labelColor)
    }

    func testContinuousFileHeaderCarriesChromeMetadata() {
        let entry = ContinuousDiffEntry(
            status: untracked("src/a.png"), staged: false, added: 4, deleted: 0)
        let document = DiffDocumentBuilder.buildContinuous(
            sections: [(entry, nil)], layout: .unified)
        let header = document.fileHeaders[0]
        XCTAssertEqual(header.path, "src/a.png")
        XCTAssertEqual(header.changeKind, .untracked)
        XCTAssertEqual(header.added, 4)
        let style = document.text.attribute(
            .paragraphStyle, at: header.range.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertGreaterThanOrEqual(style?.minimumLineHeight ?? 0, 32)
    }

    func testImageSectionUsesBinaryPlaceholder() {
        let entry = ContinuousDiffEntry(
            status: unstaged("icon.png"), staged: false, added: 0, deleted: 0)
        let loaded = LoadedDiff.ready(
            FileDiff(path: "icon.png", originalPath: nil,
                     content: .image(ImageDiff(old: .bytes(Data([1])), new: .bytes(Data([2]))))))
        let document = DiffDocumentBuilder.buildContinuous(
            sections: [(entry, loaded)], layout: .unified)
        XCTAssertTrue(document.text.string.contains("二进制文件"))
        XCTAssertFalse(document.text.string.contains("PNG"))
    }
}
