import XCTest
@testable import GitKit

final class CommitLogParserTests: XCTestCase {
    func testParsesSubjectAndMultilineBody() {
        let sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        var data = Data()
        data.append(contentsOf: sha.utf8)
        data.append(0x1f)
        data.append(contentsOf: "subject line".utf8)
        data.append(0x1f)
        data.append(contentsOf: "body line 1\nbody line 2".utf8)
        data.append(0x1f)
        data.append(contentsOf: "Ada".utf8)
        data.append(0x1f)
        data.append(contentsOf: "2026-09-14T12:00:00Z".utf8)
        data.append(0x1e)

        let commits = CommitLogParser.parse(data)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].sha, sha)
        XCTAssertEqual(commits[0].subject, "subject line")
        XCTAssertTrue(commits[0].body.contains("body line 2"))
        XCTAssertEqual(commits[0].authorName, "Ada")
        XCTAssertEqual(commits[0].shortSHA, "aaaaaaa")
    }
}
