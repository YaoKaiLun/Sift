import XCTest
@testable import UpdateKit

private struct FixtureReleaseFetcher: ReleaseFetching {
    let data: Data

    func latestReleaseData() async throws -> Data { data }
}

final class UpdateCheckerTests: XCTestCase {
    func testHigherReleaseIsAvailable() async throws {
        let fetcher = FixtureReleaseFetcher(data: GitHubLatestReleaseTests.fixtureWithDMG)
        let result = try await UpdateChecker.check(current: Version("1.0")!, fetching: fetcher)
        guard case .available(let update) = result else {
            return XCTFail("应为 available，实际是 \(result)")
        }
        XCTAssertEqual(update.version, Version("1.1"))
        XCTAssertEqual(update.dmgURL.lastPathComponent, "Sift-1.1.dmg")
    }

    func testEqualReleaseIsUpToDate() async throws {
        let fetcher = FixtureReleaseFetcher(data: GitHubLatestReleaseTests.fixtureWithDMG)
        let result = try await UpdateChecker.check(current: Version("1.1")!, fetching: fetcher)
        XCTAssertEqual(result, .upToDate)
    }

    func testMissingDmgIsNoInstallableAsset() async throws {
        let fetcher = FixtureReleaseFetcher(data: GitHubLatestReleaseTests.fixtureWithoutDMG)
        let result = try await UpdateChecker.check(current: Version("1.0")!, fetching: fetcher)
        XCTAssertEqual(result, .noInstallableAsset)
    }

    func testSynthesizedLatestReleaseIsAvailable() async throws {
        let fetcher = FixtureReleaseFetcher(data: GitHubLatestRelease.synthesizedData(tagName: "v1.2.0"))
        let result = try await UpdateChecker.check(current: Version("1.0")!, fetching: fetcher)
        guard case .available(let update) = result else {
            return XCTFail("应为 available，实际是 \(result)")
        }
        XCTAssertEqual(update.version, Version("1.2.0"))
        XCTAssertEqual(update.dmgURL.lastPathComponent, "Sift-1.2.0.dmg")
    }
}
