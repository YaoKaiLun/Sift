import XCTest
@testable import AIClient

final class ExplainPromptTests: XCTestCase {
    func testMessagesStartWithChineseSystemPromptThenCodePayload() {
        let request = ExplainRequest(
            path: "Cache.swift",
            selectedText: "return 128",
            surroundingText: "var estimated: Int { return 128 }",
            fileDiff: "+return 128",
            history: [ExplainTurn(role: .user, text: "再短一点")])

        let messages = ExplainPrompt.messages(for: request)
        XCTAssertGreaterThanOrEqual(messages.count, 3)
        XCTAssertEqual(messages[0].role, "system")
        XCTAssertTrue(messages[0].content.contains("简体中文"), "系统提示必须要求中文回答")
        XCTAssertEqual(messages[1].role, "user")
        XCTAssertTrue(messages[1].content.contains("Cache.swift"))
        XCTAssertTrue(messages[1].content.contains("return 128"))
        XCTAssertTrue(messages[1].content.contains("+return 128"))
        XCTAssertEqual(messages.last?.role, "user")
        XCTAssertEqual(messages.last?.content, "再短一点")
    }
}
