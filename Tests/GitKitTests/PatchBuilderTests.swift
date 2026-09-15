import XCTest
@testable import GitKit

final class PatchBuilderTests: XCTestCase {
    private func hunk(oldStart: Int = 1, oldCount: Int = 3,
                      newStart: Int = 1, newCount: Int = 3,
                      lines: [DiffLine]) -> Hunk {
        Hunk(oldStart: oldStart, oldCount: oldCount,
             newStart: newStart, newCount: newCount,
             sectionHeading: "", lines: lines)
    }

    func testModifiedPatchHasGitHeaders() {
        let hunk = hunk(lines: [
            DiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "a"),
            DiffLine(kind: .deletion, oldLineNumber: 2, newLineNumber: nil, text: "b"),
            DiffLine(kind: .addition, oldLineNumber: nil, newLineNumber: 2, text: "B"),
            DiffLine(kind: .context, oldLineNumber: 3, newLineNumber: 3, text: "c"),
        ])
        let patch = PatchBuilder.build(hunk: hunk, path: "src/a.txt", kind: .modified)
        XCTAssertTrue(patch.hasPrefix("diff --git a/src/a.txt b/src/a.txt\n"))
        XCTAssertTrue(patch.contains("--- a/src/a.txt\n"))
        XCTAssertTrue(patch.contains("+++ b/src/a.txt\n"))
        XCTAssertTrue(patch.contains("@@ -1,3 +1,3 @@\n"))
        XCTAssertTrue(patch.contains("-b\n"))
        XCTAssertTrue(patch.contains("+B\n"))
    }

    func testAddedFileUsesDevNull() {
        let hunk = hunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: 1, lines: [
            DiffLine(kind: .addition, oldLineNumber: nil, newLineNumber: 1, text: "new"),
        ])
        let patch = PatchBuilder.build(hunk: hunk, path: "new.txt", kind: .added)
        XCTAssertTrue(patch.contains("new file mode 100644\n"),
                       "缺少 new file mode 时 apply -R 会把 /dev/null 当成相对路径")
        XCTAssertTrue(patch.contains("--- /dev/null\n"))
        XCTAssertTrue(patch.contains("+++ b/new.txt\n"))
    }

    func testDeletedFileUsesDevNullOnNewSide() {
        let hunk = hunk(oldStart: 1, oldCount: 1, newStart: 0, newCount: 0, lines: [
            DiffLine(kind: .deletion, oldLineNumber: 1, newLineNumber: nil, text: "gone"),
        ])
        let patch = PatchBuilder.build(hunk: hunk, path: "gone.txt", kind: .deleted)
        XCTAssertTrue(patch.contains("deleted file mode 100644\n"),
                       "缺少 deleted file mode 时 apply -R 会去读相对路径 dev/null")
        XCTAssertTrue(patch.contains("--- a/gone.txt\n"))
        XCTAssertTrue(patch.contains("+++ /dev/null\n"))
    }

    func testRenameUsesOriginalPath() {
        let hunk = hunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, lines: [
            DiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "keep"),
        ])
        let patch = PatchBuilder.build(
            hunk: hunk, path: "b.txt", originalPath: "a.txt", kind: .modified)
        XCTAssertTrue(patch.contains("diff --git a/a.txt b/b.txt\n"))
        XCTAssertTrue(patch.contains("--- a/a.txt\n"))
        XCTAssertTrue(patch.contains("+++ b/b.txt\n"))
    }

    func testPatchRoundTripsThroughGitApplyCheck() async throws {
        let repo = try FixtureRepo()
        try repo.write("line1\nline2\nline3\n", to: "a.txt")
        try repo.commit("initial")
        try repo.write("line1\nCHANGED\nline3\n", to: "a.txt")
        let data = try await GitRunner().run(
            ["diff", "--no-color", "-U3", "--", "a.txt"], in: repo.url)
        let diff = DiffParser.parse(data, path: "a.txt")
        let hunk = try XCTUnwrap(diff.hunks.first)
        let patch = PatchBuilder.build(hunk: hunk, path: "a.txt", kind: .modified)
        try repo.git("checkout", "--", "a.txt")
        _ = try await GitRunner().run(
            ["apply", "--check"], in: repo.url, stdin: Data(patch.utf8))
    }
}
