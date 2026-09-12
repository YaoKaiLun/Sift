import XCTest
import AppKit
import GitKit
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

    /// 性能护栏：大 diff 的文档构建必须够快，不然点开文件那 100ms 预算就爆了。
    func testBuildsLargeDocumentQuickly() {
        let lines = (0..<10_000).map { index in
            DiffLine(kind: index % 3 == 0 ? .addition : .context,
                     oldLineNumber: index, newLineNumber: index,
                     text: "some source code line number \(index)")
        }
        let diff = makeDiff(lines)
        let start = ContinuousClock.now
        _ = DiffDocumentBuilder.build(diff)
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .milliseconds(50),
                          "10000 行的文档构建耗时 \(elapsed)，超出预算")
    }
}
