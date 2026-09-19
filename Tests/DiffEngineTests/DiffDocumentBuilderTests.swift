import XCTest
import AppKit
import GitKit
import DiffEngine
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
        let document = DiffDocumentBuilder.build(diff)
        let text = document.text.string
        XCTAssertTrue(text.contains("keep"))
        XCTAssertTrue(text.contains("gone"))
        XCTAssertTrue(text.contains("fresh"))
    }

    func testIncludesHunkHeading() {
        let diff = makeDiff([
            DiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "keep"),
        ])
        XCTAssertTrue(DiffDocumentBuilder.build(diff).text.string
            .contains("func example()"))
    }

    func testAdditionLineCarriesAdditionBackground() {
        let diff = makeDiff([
            DiffLine(kind: .addition, oldLineNumber: nil, newLineNumber: 1, text: "fresh"),
        ])
        let document = DiffDocumentBuilder.build(diff).text
        let range = (document.string as NSString).range(of: "fresh")
        let attributes = document.attributes(at: range.location, effectiveRange: nil)
        XCTAssertNotNil(attributes[.backgroundColor], "新增行必须有背景色")
    }

    func testUsesMonospacedFontThroughout() {
        let diff = makeDiff([
            DiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "keep"),
        ])
        let document = DiffDocumentBuilder.build(diff).text
        let font = document.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        XCTAssertTrue(font!.isFixedPitch, "代码必须用等宽字体")
    }

    func testLineNumbersAppearInGutter() {
        let diff = makeDiff([
            DiffLine(kind: .context, oldLineNumber: 42, newLineNumber: 43, text: "keep"),
        ], oldStart: 42, newStart: 43)
        let text = DiffDocumentBuilder.build(diff).text.string
        XCTAssertTrue(text.contains("42"))
        XCTAssertTrue(text.contains("43"))
    }

    func testEmptyDiffProducesEmptyDocument() {
        let diff = FileDiff(path: "a.swift", originalPath: nil, content: .empty)
        XCTAssertEqual(DiffDocumentBuilder.build(diff).text.length, 0)
    }

    func testBuildOffMainActorMatchesBuild() async {
        let diff = makeDiff([
            DiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "keep"),
            DiffLine(kind: .addition, oldLineNumber: nil, newLineNumber: 2, text: "fresh"),
        ])
        let onThread = DiffDocumentBuilder.build(diff)
        let offMain = await DiffDocumentBuilder.buildOffMainActor(diff)
        XCTAssertEqual(onThread.text.string, offMain.text.string)
        XCTAssertEqual(onThread.text.length, offMain.text.length)
    }

    func testRecordsHunkHeaderRanges() {
        let diff = makeDiff([
            DiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "keep"),
        ])
        let document = DiffDocumentBuilder.build(diff)
        XCTAssertEqual(document.hunkHeaders.count, 1)
        let header = document.hunkHeaders[0]
        XCTAssertEqual(header.id, diff.hunks[0].id)
        let headerText = (document.text.string as NSString).substring(with: header.range)
        XCTAssertTrue(headerText.hasPrefix("@@"))
    }

    func testCodeLinesUseComfortableLineHeight() {
        let document = DiffDocumentBuilder.build(makeDiff([
            DiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "keep"),
        ]))
        let body = document.hunkHeaders[0].range
        let style = document.text.attribute(
            .paragraphStyle, at: body.location + body.length, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.minimumLineHeight, Theme.codeLineHeight)
        XCTAssertEqual(Theme.codeLineHeight, 19)
    }

    func testHunkHeaderLineIsTallerThanCode() {
        let document = DiffDocumentBuilder.build(makeDiff([
            DiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "keep"),
        ]))
        let header = document.hunkHeaders[0]
        let headerStyle = document.text.attribute(
            .paragraphStyle, at: header.range.location, effectiveRange: nil) as? NSParagraphStyle
        let bodyStyle = document.text.attribute(
            .paragraphStyle, at: header.range.location + header.range.length,
            effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(headerStyle?.minimumLineHeight, Theme.hunkHeaderLineHeight)
        XCTAssertEqual(headerStyle?.maximumLineHeight, Theme.hunkHeaderLineHeight)
        XCTAssertGreaterThan(headerStyle?.minimumLineHeight ?? 0,
                             bodyStyle?.minimumLineHeight ?? 0)
        XCTAssertEqual(Theme.hunkHeaderLineHeight, 24)
    }

    func testHunkHeaderUsesOpaqueChromeAndCenteredBaseline() {
        let document = DiffDocumentBuilder.build(makeDiff([
            DiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "keep"),
        ]))
        let header = document.hunkHeaders[0]
        let bg = document.text.attribute(
            .backgroundColor, at: header.range.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(bg, NSColor.controlBackgroundColor)
        let offset = document.text.attribute(
            .baselineOffset, at: header.range.location, effectiveRange: nil) as? CGFloat
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        XCTAssertEqual(offset, DiffDocumentBuilder.hunkHeaderBaselineOffset(font: font))
        XCTAssertLessThan(offset ?? 0, 0, "多出来的行高要往下匀，字才在灰条中间")
    }

    func testNewLineNumberUsesLastIntegerField() {
        XCTAssertEqual(DiffDocumentBuilder.newLineNumber(fromGutter: "   1    2 "), 2)
        XCTAssertEqual(DiffDocumentBuilder.newLineNumber(fromGutter: "9999 10000 "), 10000)
        XCTAssertEqual(DiffDocumentBuilder.newLineNumber(fromGutter: "10000 10001 "), 10001)
        XCTAssertEqual(DiffDocumentBuilder.newLineNumber(fromGutter: " 10000 "), 10000)
        XCTAssertNil(DiffDocumentBuilder.newLineNumber(fromGutter: "          "))
    }

    func testBlameLineNumberUsesOldSideAndSkipsAdditions() {
        XCTAssertEqual(DiffDocumentBuilder.blameLineNumber(fromGutter: "  33   34 ", marker: " "), 33)
        XCTAssertEqual(DiffDocumentBuilder.blameLineNumber(fromGutter: "  33      ", marker: "-"), 33)
        XCTAssertEqual(DiffDocumentBuilder.blameLineNumber(fromGutter: "10000 10001 ", marker: " "), 10000)
        XCTAssertNil(DiffDocumentBuilder.blameLineNumber(fromGutter: "       34 ", marker: "+"))
        XCTAssertNil(DiffDocumentBuilder.blameLineNumber(fromGutter: "          ", marker: "-"))
    }

    func testBlameLineNumberFromBuiltDeletionGutter() {
        let diff = makeDiff([
            DiffLine(kind: .deletion, oldLineNumber: 33, newLineNumber: nil, text: "gone"),
            DiffLine(kind: .addition, oldLineNumber: nil, newLineNumber: 34, text: "fresh"),
        ], oldStart: 33, newStart: 33)
        let document = DiffDocumentBuilder.build(diff, layout: .unified)
        let ns = document.text.string as NSString

        func gutter(around needle: String) -> (gutter: String, marker: Character) {
            let code = ns.range(of: needle)
            let line = ns.lineRange(for: code)
            var gutter = ""
            var marker: Character?
            document.text.enumerateAttributes(in: line, options: []) { attrs, run, _ in
                let role = attrs[.siftRole] as? String
                if role == "gutter" {
                    gutter += ns.substring(with: run)
                } else if role == "code", marker == nil {
                    marker = ns.substring(with: run).first
                }
            }
            return (gutter, marker ?? " ")
        }

        let deleted = gutter(around: "gone")
        XCTAssertEqual(DiffDocumentBuilder.blameLineNumber(fromGutter: deleted.gutter, marker: deleted.marker), 33)
        let added = gutter(around: "fresh")
        XCTAssertNil(DiffDocumentBuilder.blameLineNumber(fromGutter: added.gutter, marker: added.marker))
    }

    func testNewLineNumberFromBuiltFiveDigitGutter() {
        let diff = makeDiff([
            DiffLine(kind: .context, oldLineNumber: 9999, newLineNumber: 10000, text: "keep"),
        ], oldStart: 9999, newStart: 10000)
        let document = DiffDocumentBuilder.build(diff, layout: .unified)
        let ns = document.text.string as NSString
        let code = ns.range(of: "keep")
        let line = ns.lineRange(for: code)
        var gutter = ""
        document.text.enumerateAttributes(in: line, options: []) { attrs, run, _ in
            if attrs[.siftRole] as? String == "gutter" {
                gutter += ns.substring(with: run)
            }
        }
        XCTAssertEqual(DiffDocumentBuilder.newLineNumber(fromGutter: gutter), 10000)
    }

    func testGutterRunsAreMarked() {
        let diff = makeDiff([
            DiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "keep"),
        ])
        let document = DiffDocumentBuilder.build(diff, layout: .unified)
        let text = document.text
        let range = (text.string as NSString).range(of: "keep")
        let role = text.attribute(.siftRole, at: range.location, effectiveRange: nil) as? String
        XCTAssertEqual(role, "code")
        // 文档开头是 hunk 头（header），gutter 在含 keep 的那一行行首。
        let lineStart = (text.string as NSString).lineRange(for: range).location
        let gutterRole = text.attribute(.siftRole, at: lineStart, effectiveRange: nil) as? String
        XCTAssertEqual(gutterRole, "gutter")
    }

    func testSplitPutsDeletionOnLeftAndAdditionOnRight() throws {
        let diff = makeDiff([
            DiffLine(kind: .deletion, oldLineNumber: 1, newLineNumber: nil, text: "gone"),
            DiffLine(kind: .addition, oldLineNumber: nil, newLineNumber: 1, text: "fresh"),
        ])
        let document = DiffDocumentBuilder.build(diff, layout: .split)
        XCTAssertTrue(document.splitLeft.string.contains("gone"))
        XCTAssertFalse(document.splitLeft.string.contains("fresh"))
        let right = try XCTUnwrap(document.splitRight)
        XCTAssertTrue(right.string.contains("fresh"))
        XCTAssertFalse(right.string.contains("gone"))
    }

    func testCopyableStringDropsGutter() {
        let diff = makeDiff([
            DiffLine(kind: .addition, oldLineNumber: nil, newLineNumber: 1, text: "fresh"),
        ])
        let document = DiffDocumentBuilder.build(diff, layout: .unified)
        let copied = DiffDocumentBuilder.copyableString(from: document.text,
            range: NSRange(location: 0, length: document.text.length))
        XCTAssertFalse(copied.contains("   1"), "行号不应出现在复制结果里")
        XCTAssertTrue(copied.contains("+fresh") || copied.contains("fresh"))
    }

    func testSurroundingRangeIncludesEightLinesEachSide() {
        var lines: [DiffLine] = []
        for number in 1...20 {
            lines.append(DiffLine(
                kind: .context,
                oldLineNumber: number,
                newLineNumber: number,
                text: "LINE_\(number)_END"))
        }
        let document = DiffDocumentBuilder.build(makeDiff(lines, oldStart: 1, newStart: 1))
        let ns = document.text.string as NSString
        let target = ns.range(of: "LINE_10_END")
        XCTAssertNotEqual(target.location, NSNotFound)

        let surrounding = DiffDocumentBuilder.surroundingRange(
            of: target, in: document.text.string, extraLines: 8)
        let copied = DiffDocumentBuilder.copyableString(from: document.text, range: surrounding)
        XCTAssertTrue(copied.contains("LINE_2_END"), "选区前 8 行应包含 line2")
        XCTAssertTrue(copied.contains("LINE_18_END"), "选区后 8 行应包含 line18")
        XCTAssertFalse(copied.contains("LINE_1_END"), "再往前第 9 行不应进入上下文")
        XCTAssertFalse(copied.contains("LINE_19_END"), "再往后第 9 行不应进入上下文")
    }

    func testCodeReferenceUsesPathAndNewLineNumber() {
        let document = DiffDocumentBuilder.build(makeDiff([
            DiffLine(kind: .addition, oldLineNumber: nil, newLineNumber: 12, text: "fresh"),
        ], oldStart: 11, newStart: 12))
        let range = (document.text.string as NSString).range(of: "fresh")
        let copied = DiffDocumentBuilder.codeReferenceString(
            from: document.text, range: range, fallbackPath: "a.swift")
        XCTAssertEqual(copied, """
        ```a.swift:12
        +fresh
        ```
        """)
    }

    func testCodeReferenceSingleLineDoesNotUseRange() {
        let document = DiffDocumentBuilder.build(makeDiff([
            DiffLine(kind: .context, oldLineNumber: 4, newLineNumber: 4, text: "keep"),
        ], oldStart: 4, newStart: 4))
        let range = (document.text.string as NSString).range(of: "keep")
        let copied = DiffDocumentBuilder.codeReferenceString(
            from: document.text, range: range, fallbackPath: "a.swift")
        XCTAssertTrue(copied.hasPrefix("```a.swift:4\n"))
        XCTAssertFalse(copied.contains("4-4"))
    }

    func testCodeReferenceUsesLineRangeForEmptySelection() {
        let document = DiffDocumentBuilder.build(makeDiff([
            DiffLine(kind: .addition, oldLineNumber: nil, newLineNumber: 2, text: "fresh"),
        ], oldStart: 1, newStart: 1))
        let needle = (document.text.string as NSString).range(of: "fresh")
        let caret = NSRange(location: needle.location, length: 0)
        let copied = DiffDocumentBuilder.codeReferenceString(
            from: document.text, range: caret, fallbackPath: "a.swift")
        XCTAssertTrue(copied.contains("```a.swift:2\n"))
        XCTAssertTrue(copied.contains("+fresh"))
    }

    func testCodeReferenceDropsGutter() {
        let document = DiffDocumentBuilder.build(makeDiff([
            DiffLine(kind: .context, oldLineNumber: 42, newLineNumber: 43, text: "keep"),
        ], oldStart: 42, newStart: 43))
        let copied = DiffDocumentBuilder.codeReferenceString(
            from: document.text,
            range: NSRange(location: 0, length: document.text.length),
            fallbackPath: "a.swift")
        XCTAssertFalse(copied.contains("  42"))
        XCTAssertTrue(copied.contains(" keep") || copied.contains("keep"))
        XCTAssertTrue(copied.contains("```a.swift:43"))
    }

    func testCodeReferenceSpansLineRange() {
        let document = DiffDocumentBuilder.build(makeDiff([
            DiffLine(kind: .context, oldLineNumber: 10, newLineNumber: 10, text: "one"),
            DiffLine(kind: .context, oldLineNumber: 11, newLineNumber: 11, text: "two"),
            DiffLine(kind: .addition, oldLineNumber: nil, newLineNumber: 12, text: "three"),
        ], oldStart: 10, newStart: 10))
        let copied = DiffDocumentBuilder.codeReferenceString(
            from: document.text,
            range: NSRange(location: 0, length: document.text.length),
            fallbackPath: "a.swift")
        XCTAssertTrue(copied.hasPrefix("```a.swift:10-12\n"))
        XCTAssertTrue(copied.contains(" one") || copied.contains("one"))
        XCTAssertTrue(copied.contains("+three"))
    }

    func testCodeReferenceTruncatesExtraLines() {
        var lines: [DiffLine] = []
        for number in 1...5 {
            lines.append(DiffLine(
                kind: .context, oldLineNumber: number, newLineNumber: number,
                text: "LINE_\(number)"))
        }
        let document = DiffDocumentBuilder.build(makeDiff(lines))
        let ns = document.text.string as NSString
        let start = ns.range(of: "LINE_1")
        let end = ns.range(of: "LINE_5")
        let range = NSRange(location: start.location, length: NSMaxRange(end) - start.location)
        let copied = DiffDocumentBuilder.codeReferenceString(
            from: document.text,
            range: range,
            fallbackPath: "a.swift",
            maxLines: 2)
        XCTAssertTrue(copied.contains("LINE_1"))
        XCTAssertTrue(copied.contains("LINE_2"))
        XCTAssertFalse(copied.contains("LINE_3"))
        XCTAssertTrue(copied.contains("… (truncated, 3 more lines)"))
    }

    func testCodeReferenceUsesOldLineNumbersOnLeftSplit() throws {
        let document = DiffDocumentBuilder.build(makeDiff([
            DiffLine(kind: .deletion, oldLineNumber: 8, newLineNumber: nil, text: "gone"),
            DiffLine(kind: .addition, oldLineNumber: nil, newLineNumber: 8, text: "fresh"),
        ], oldStart: 8, newStart: 8), layout: .split)
        let range = (document.text.string as NSString).range(of: "gone")
        let copied = DiffDocumentBuilder.codeReferenceString(
            from: document.text, range: range, fallbackPath: "a.swift",
            usesNewLineNumbers: false)
        XCTAssertTrue(copied.contains("```a.swift:8\n"))
        XCTAssertTrue(copied.contains("-gone"))

        let right = try XCTUnwrap(document.splitRight)
        let rightRange = (right.string as NSString).range(of: "fresh")
        let rightCopied = DiffDocumentBuilder.codeReferenceString(
            from: right, range: rightRange, fallbackPath: "a.swift",
            usesNewLineNumbers: true)
        XCTAssertTrue(rightCopied.contains("```a.swift:8\n"))
        XCTAssertTrue(rightCopied.contains("+fresh"))
    }

    func testCodeReferenceSplitsFencesAcrossFiles() {
        let first = ContinuousDiffEntry(
            status: FileStatus(path: "a.swift", originalPath: nil,
                               indexStatus: .modified, worktreeStatus: .unmodified),
            staged: true, added: 1, deleted: 0)
        let second = ContinuousDiffEntry(
            status: FileStatus(path: "b.swift", originalPath: nil,
                               indexStatus: .unmodified, worktreeStatus: .modified),
            staged: false, added: 1, deleted: 0)
        let hunkA = Hunk(oldStart: 1, oldCount: 0, newStart: 1, newCount: 1,
                         sectionHeading: "",
                         lines: [DiffLine(kind: .addition, oldLineNumber: nil, newLineNumber: 1, text: "alpha")])
        let hunkB = Hunk(oldStart: 2, oldCount: 0, newStart: 2, newCount: 1,
                         sectionHeading: "",
                         lines: [DiffLine(kind: .addition, oldLineNumber: nil, newLineNumber: 2, text: "beta")])
        let document = DiffDocumentBuilder.buildContinuous(sections: [
            (first, .ready(FileDiff(path: "a.swift", originalPath: nil, content: .textual([hunkA])))),
            (second, .ready(FileDiff(path: "b.swift", originalPath: nil, content: .textual([hunkB])))),
        ])
        let copied = DiffDocumentBuilder.codeReferenceString(
            from: document.text,
            range: NSRange(location: 0, length: document.text.length),
            fallbackPath: "fallback.swift",
            fileHeaders: document.fileHeaders)
        XCTAssertTrue(copied.contains("```a.swift:1\n"))
        XCTAssertTrue(copied.contains("+alpha"))
        XCTAssertTrue(copied.contains("```b.swift:2\n"))
        XCTAssertTrue(copied.contains("+beta"))
        XCTAssertFalse(copied.contains("fallback.swift"))
    }

    func testCodeReferenceEmptyDocumentIsEmpty() {
        let copied = DiffDocumentBuilder.codeReferenceString(
            from: NSAttributedString(), range: NSRange(location: 0, length: 0),
            fallbackPath: "a.swift")
        XCTAssertEqual(copied, "")
    }

}
