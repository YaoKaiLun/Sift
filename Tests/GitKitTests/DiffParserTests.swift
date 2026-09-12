import XCTest
@testable import GitKit

final class DiffParserTests: XCTestCase {
    private let runner = GitRunner()

    private func diff(_ repo: FixtureRepo, path: String, staged: Bool = false) async throws -> FileDiff {
        var args = ["diff", "--no-color", "-U3"]
        if staged { args.append("--cached") }
        args += ["--", path]
        let data = try await runner.run(args, in: repo.url)
        return DiffParser.parse(data, path: path)
    }

    func testSimpleModification() async throws {
        let repo = try FixtureRepo()
        try repo.write("line1\nline2\nline3\n", to: "a.txt")
        try repo.commit("initial")
        try repo.write("line1\nCHANGED\nline3\n", to: "a.txt")

        let result = try await diff(repo, path: "a.txt")
        XCTAssertEqual(result.path, "a.txt")
        XCTAssertEqual(result.hunks.count, 1)
        XCTAssertEqual(result.addedLineCount, 1)
        XCTAssertEqual(result.deletedLineCount, 1)

        let hunk = result.hunks[0]
        XCTAssertEqual(hunk.oldStart, 1)
        XCTAssertEqual(hunk.newStart, 1)
        let added = try XCTUnwrap(hunk.lines.first { $0.kind == .addition })
        XCTAssertEqual(added.text, "CHANGED")
        XCTAssertEqual(added.newLineNumber, 2)
        XCTAssertNil(added.oldLineNumber)
    }

    func testLineNumbersAreCorrectAcrossHunk() async throws {
        let repo = try FixtureRepo()
        let original = (1...20).map { "line\($0)" }.joined(separator: "\n") + "\n"
        try repo.write(original, to: "a.txt")
        try repo.commit("initial")
        var lines = (1...20).map { "line\($0)" }
        lines[9] = "MODIFIED"
        try repo.write(lines.joined(separator: "\n") + "\n", to: "a.txt")

        let result = try await diff(repo, path: "a.txt")
        let hunk = try XCTUnwrap(result.hunks.first)
        let modified = try XCTUnwrap(hunk.lines.first { $0.kind == .addition })
        XCTAssertEqual(modified.newLineNumber, 10)
        let context = try XCTUnwrap(hunk.lines.first { $0.kind == .context })
        XCTAssertEqual(context.oldLineNumber, context.newLineNumber,
                       "本例中上下文行前后行号应一致")
    }

    func testMultipleHunks() async throws {
        let repo = try FixtureRepo()
        let original = (1...60).map { "line\($0)" }.joined(separator: "\n") + "\n"
        try repo.write(original, to: "a.txt")
        try repo.commit("initial")
        var lines = (1...60).map { "line\($0)" }
        lines[2] = "FIRST CHANGE"
        lines[50] = "SECOND CHANGE"
        try repo.write(lines.joined(separator: "\n") + "\n", to: "a.txt")

        let result = try await diff(repo, path: "a.txt")
        XCTAssertEqual(result.hunks.count, 2)
    }

    func testStagedDiff() async throws {
        let repo = try FixtureRepo()
        try repo.write("line1\n", to: "a.txt")
        try repo.commit("initial")
        try repo.write("staged change\n", to: "a.txt")
        try repo.git("add", "a.txt")

        let result = try await diff(repo, path: "a.txt", staged: true)
        XCTAssertEqual(result.addedLineCount, 1)
    }

    func testBinaryFile() async throws {
        let repo = try FixtureRepo()
        try repo.write("placeholder\n", to: "img.bin")
        try repo.commit("initial")
        let binary = Data((0..<512).map { UInt8($0 % 256) })
        try binary.write(to: repo.url.appendingPathComponent("img.bin"))

        let result = try await diff(repo, path: "img.bin")
        XCTAssertEqual(result.content, .binary)
    }

    func testNoNewlineAtEndOfFile() async throws {
        let repo = try FixtureRepo()
        try repo.write("line1\n", to: "a.txt")
        try repo.commit("initial")
        try repo.write("line1\nno trailing newline", to: "a.txt")

        let result = try await diff(repo, path: "a.txt")
        let hunk = try XCTUnwrap(result.hunks.first)
        XCTAssertTrue(hunk.lines.contains { $0.kind == .noNewlineMarker },
                      "应识别出 \\ No newline at end of file 标记")
    }

    func testEmptyDiffWhenNoChanges() async throws {
        let repo = try FixtureRepo()
        try repo.write("line1\n", to: "a.txt")
        try repo.commit("initial")

        let result = try await diff(repo, path: "a.txt")
        XCTAssertEqual(result.content, .empty)
    }

    func testLinesStartingWithPlusOrMinusInContent() async throws {
        let repo = try FixtureRepo()
        try repo.write("normal\n", to: "a.txt")
        try repo.commit("initial")
        // 内容本身以 + 和 - 开头，解析时必须靠位置而非内容判断。
        try repo.write("normal\n++ not a header\n-- also not\n", to: "a.txt")

        let result = try await diff(repo, path: "a.txt")
        let added = result.hunks.flatMap(\.lines).filter { $0.kind == .addition }
        XCTAssertEqual(added.count, 2)
        XCTAssertEqual(added[0].text, "++ not a header")
        XCTAssertEqual(added[1].text, "-- also not")
    }

    func testPatchTextRoundTripsThroughGitApply() async throws {
        let repo = try FixtureRepo()
        try repo.write("line1\nline2\nline3\n", to: "a.txt")
        try repo.commit("initial")
        try repo.write("line1\nCHANGED\nline3\n", to: "a.txt")

        let result = try await diff(repo, path: "a.txt")
        let hunk = try XCTUnwrap(result.hunks.first)
        // 构造一个完整 patch 并用 --check 验证 git 认可它的格式。
        // 计划二的 hunk 级 stage/discard 完全依赖这一点。
        let patch = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        \(hunk.patchText)
        """
        let patchURL = repo.url.appendingPathComponent("test.patch")
        try patch.write(to: patchURL, atomically: true, encoding: .utf8)
        try repo.git("checkout", "--", "a.txt")
        try repo.git("apply", "--check", "test.patch")
    }
}
