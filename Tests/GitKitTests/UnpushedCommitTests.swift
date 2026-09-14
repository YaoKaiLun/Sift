import XCTest
@testable import GitKit

final class UnpushedCommitTests: XCTestCase {
    func testUnpushedCommitsNilWithoutUpstream() async throws {
        let fixture = try FixtureRepo()
        try fixture.write("a\n", to: "a.txt")
        try fixture.commit("initial")
        let commits = try await GitRepository(root: fixture.url).unpushedCommits()
        XCTAssertNil(commits)
    }

    func testUnpushedCommitsListsNewCommits() async throws {
        let origin = try FixtureRepo()
        try origin.write("a\n", to: "a.txt")
        try origin.commit("initial")
        let cloneURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-unpushed-\(UUID().uuidString)")
        try origin.git("clone", origin.url.path, cloneURL.path)
        defer { try? FileManager.default.removeItem(at: cloneURL) }
        let b = cloneURL.appendingPathComponent("b.txt")
        try Data("new\n".utf8).write(to: b)
        try runGit(["config", "user.email", "test@sift.local"], in: cloneURL)
        try runGit(["config", "user.name", "Sift Test"], in: cloneURL)
        try runGit(["config", "commit.gpgsign", "false"], in: cloneURL)
        try runGit(["add", "b.txt"], in: cloneURL)
        try runGit(["commit", "-m", "add b", "-m", "body line"], in: cloneURL)

        let repo = GitRepository(root: cloneURL)
        let commits = try await repo.unpushedCommits()
        XCTAssertEqual(commits?.count, 1)
        XCTAssertEqual(commits?.first?.subject, "add b")
        XCTAssertEqual(commits?.first?.body.trimmingCharacters(in: .whitespacesAndNewlines), "body line")
        let sha = try XCTUnwrap(commits?.first?.sha)
        let files = try await repo.commitFiles(sha: sha)
        XCTAssertEqual(files.files.map(\.path), ["b.txt"])
        let diff = try await repo.diff(path: "b.txt", from: try await repo.commitParent(sha: sha), to: sha)
        XCTAssertGreaterThan(diff.addedLineCount, 0)
    }

    private func runGit(_ args: [String], in url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = url
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " ")) failed")
    }
}
