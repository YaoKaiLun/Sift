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
}
