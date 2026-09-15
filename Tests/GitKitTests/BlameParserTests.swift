import XCTest
@testable import GitKit

final class BlameParserTests: XCTestCase {
    func testParsesAuthorTimeSummaryAndNewLineNumber() {
        let porcelain = """
        abcdefabcdefabcdefabcdefabcdefabcdefabcd 4 7 1
        author Ada Lovelace
        author-mail <ada@example.com>
        author-time 1700000000
        author-tz +0000
        committer Sift Test
        committer-mail <test@sift.local>
        committer-time 1700000000
        committer-tz +0000
        summary first commit
        filename a.txt
        \tline seven
        """
        let lines = BlameParser.parse(Data(porcelain.utf8))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].sha, "abcdefabcdefabcdefabcdefabcdefabcdefabcd")
        XCTAssertEqual(lines[0].author, "Ada Lovelace")
        XCTAssertEqual(lines[0].authorTime, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(lines[0].summary, "first commit")
        XCTAssertEqual(lines[0].newLineNumber, 7)
    }

    func testReusesMetadataForLaterLinesOfSameSha() {
        let sha = "abcdefabcdefabcdefabcdefabcdefabcdefabcd"
        let porcelain = """
        \(sha) 1 1 2
        author Ada Lovelace
        author-time 1700000000
        summary first commit
        filename a.txt
        \tline1
        \(sha) 2 2
        \tline2
        fedcbafedcbafedcbafedcbafedcbafedcbafedc 3 3 1
        author Bob
        author-time 1700000100
        summary second
        filename a.txt
        \tline3
        """
        let lines = BlameParser.parse(Data(porcelain.utf8))
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].author, "Ada Lovelace")
        XCTAssertEqual(lines[0].newLineNumber, 1)
        XCTAssertEqual(lines[1].sha, sha)
        XCTAssertEqual(lines[1].author, "Ada Lovelace")
        XCTAssertEqual(lines[1].summary, "first commit")
        XCTAssertEqual(lines[1].newLineNumber, 2)
        XCTAssertEqual(lines[2].author, "Bob")
        XCTAssertEqual(lines[2].newLineNumber, 3)
    }

    func testEmptyDataReturnsNoLines() {
        XCTAssertEqual(BlameParser.parse(Data()), [])
    }

    func testUnmodifiedLineShaEqualsHead() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("line1\nline2\nline3\n", to: "a.txt")
        try fixture.commit("initial")
        let head = try fixture.git("rev-parse", "HEAD")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.write("line1\nCHANGED\nline3\n", to: "a.txt")

        let lines = await GitRepository(root: fixture.url).blame(path: "a.txt", staged: false)
        let unchanged = try XCTUnwrap(lines.first { $0.newLineNumber == 1 })
        XCTAssertEqual(unchanged.sha, head)
        XCTAssertEqual(unchanged.author, "Sift Test")
        XCTAssertEqual(unchanged.summary, "initial")
    }

    func testUntrackedPathReturnsEmpty() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("tracked\n", to: "a.txt")
        try fixture.commit("initial")
        try fixture.write("new\n", to: "new.txt")

        let lines = await GitRepository(root: fixture.url).blame(path: "new.txt", staged: false)
        XCTAssertEqual(lines, [])
    }

    func testBinaryPathReturnsEmpty() async throws {
        let fixture = try FixtureRepo()
        try Data((0..<512).map { UInt8($0 % 256) })
            .write(to: fixture.url.appendingPathComponent("img.bin"))
        try fixture.commit("initial")

        let lines = await GitRepository(root: fixture.url).blame(path: "img.bin", staged: false)
        XCTAssertEqual(lines, [])
    }

    func testBlameUsesHeadSoDeletedLinesKeepTheirAuthor() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("keep\ndelete-me\nalso-keep\n", to: "a.txt")
        try fixture.commit("initial")
        let head = try fixture.git("rev-parse", "HEAD")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.write("keep\nalso-keep\n", to: "a.txt")

        let unstaged = await GitRepository(root: fixture.url).blame(path: "a.txt", staged: false)
        XCTAssertEqual(unstaged.map(\.newLineNumber), [1, 2, 3],
                       "必须 blame HEAD：工作区已删掉的第 2 行仍应出现")
        XCTAssertEqual(try XCTUnwrap(unstaged.first { $0.newLineNumber == 2 }).sha, head)

        try fixture.git("add", "a.txt")
        let staged = await GitRepository(root: fixture.url).blame(path: "a.txt", staged: true)
        XCTAssertEqual(try XCTUnwrap(staged.first { $0.newLineNumber == 2 }).sha, head)
    }

    func testShowCommitReturnsHeaderAndPatch() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("line1\n", to: "a.txt")
        try fixture.commit("hello world")
        let sha = try fixture.git("rev-parse", "HEAD")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = await GitRepository(root: fixture.url).showCommit(sha: sha)
        let unwrapped = try XCTUnwrap(shown)
        XCTAssertTrue(unwrapped.header.contains("hello world"))
        XCTAssertTrue(unwrapped.patch.contains("diff --git"))
        let missing = await GitRepository(root: fixture.url).showCommit(sha: String(repeating: "0", count: 40))
        XCTAssertNil(missing)
    }

    func testShowCommitHeaderDoesNotLoadPatch() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("line1\n", to: "a.txt")
        try fixture.write("line2\n", to: "b.txt")
        try fixture.commit("header only")
        let sha = try fixture.git("rev-parse", "HEAD")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let loadedHeader = await GitRepository(root: fixture.url).showCommitHeader(sha: sha)
        let header = try XCTUnwrap(loadedHeader)

        XCTAssertTrue(header.contains("header only"))
        XCTAssertFalse(header.contains("diff --git"))
        let missing = await GitRepository(root: fixture.url)
            .showCommitHeader(sha: String(repeating: "0", count: 40))
        XCTAssertNil(missing)
    }
}
