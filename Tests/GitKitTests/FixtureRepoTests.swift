import XCTest
@testable import GitKit

final class FixtureRepoTests: XCTestCase {
    func testCreatesRepositoryWithCommit() throws {
        let repo = try FixtureRepo()
        try repo.write("hello\n", to: "a.txt")
        try repo.commit("initial")

        let log = try repo.git("log", "--oneline")
        XCTAssertTrue(log.contains("initial"), "期望日志包含提交信息，实际是：\(log)")
    }

    func testWriteCreatesIntermediateDirectories() throws {
        let repo = try FixtureRepo()
        try repo.write("x\n", to: "deep/nested/dir/file.txt")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repo.url.appendingPathComponent("deep/nested/dir/file.txt").path))
    }

    func testNonZeroExitThrows() throws {
        let repo = try FixtureRepo()
        XCTAssertThrowsError(try repo.git("this-is-not-a-git-command"))
    }
}
