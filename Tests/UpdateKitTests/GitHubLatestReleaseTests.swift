import XCTest
@testable import UpdateKit

final class GitHubLatestReleaseTests: XCTestCase {
    static let fixtureWithDMG = Data("""
    {
      "tag_name": "v1.1",
      "assets": [
        {"name": "notes.txt", "browser_download_url": "https://example.com/notes.txt"},
        {"name": "Sift-1.1.dmg", "browser_download_url": "https://github.com/YaoKaiLun/Sift/releases/download/v1.1/Sift-1.1.dmg"}
      ]
    }
    """.utf8)

    static let fixtureWithoutDMG = Data("""
    {
      "tag_name": "v1.1",
      "assets": [
        {"name": "Sift-1.1.zip", "browser_download_url": "https://example.com/Sift-1.1.zip"}
      ]
    }
    """.utf8)

    func testDecodeExtractsDmgURL() throws {
        let release = try GitHubLatestRelease.decode(Self.fixtureWithDMG)
        XCTAssertEqual(release.tagName, "v1.1")
        XCTAssertEqual(release.version, Version("1.1"))
        XCTAssertEqual(
            release.dmgURL,
            URL(string: "https://github.com/YaoKaiLun/Sift/releases/download/v1.1/Sift-1.1.dmg"))
    }

    func testMissingDmgLeavesURLNil() throws {
        let release = try GitHubLatestRelease.decode(Self.fixtureWithoutDMG)
        XCTAssertNil(release.dmgURL)
        XCTAssertEqual(release.version, Version("1.1"))
    }

    func testTagNameFromReleasePageURL() {
        let url = URL(string: "https://github.com/YaoKaiLun/Sift/releases/tag/v1.2.0")!
        XCTAssertEqual(GitHubLatestRelease.tagName(fromReleasePage: url), "v1.2.0")
        XCTAssertNil(GitHubLatestRelease.tagName(
            fromReleasePage: URL(string: "https://github.com/YaoKaiLun/Sift/releases/latest")!))
    }

    func testSynthesizedReleaseUsesConventionalDMG() throws {
        let data = GitHubLatestRelease.synthesizedData(tagName: "v1.2.0")
        let release = try GitHubLatestRelease.decode(data)
        XCTAssertEqual(release.tagName, "v1.2.0")
        XCTAssertEqual(release.version, Version("1.2.0"))
        XCTAssertEqual(
            release.dmgURL,
            URL(string: "https://github.com/YaoKaiLun/Sift/releases/download/v1.2.0/Sift-1.2.0.dmg"))
    }
}
