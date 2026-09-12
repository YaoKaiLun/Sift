import XCTest
@testable import Highlighter

final class HighlighterTests: XCTestCase {
    func testSwiftKeywordsAndString() {
        let spans = Highlighter().tokens(in: "let x = \"hi\" // c", path: "a.swift")
        XCTAssertTrue(spans.contains { $0.kind == .keyword })
        XCTAssertTrue(spans.contains { $0.kind == .string })
        XCTAssertTrue(spans.contains { $0.kind == .comment })
    }

    func testUnknownExtensionReturnsNothing() {
        XCTAssertTrue(Highlighter().tokens(in: "let x = 1", path: "a.txt").isEmpty)
    }

    func testJSONKeysAreStrings() {
        let spans = Highlighter().tokens(in: "{\"a\": 1}", path: "a.json")
        XCTAssertTrue(spans.contains { $0.kind == .string })
        XCTAssertTrue(spans.contains { $0.kind == .number })
    }
}
