import XCTest
import UpdateKit
import SiftLocalization
@testable import SiftUI

private struct FixtureReleaseFetcher: ReleaseFetching {
    let data: Data
    func latestReleaseData() async throws -> Data { data }
}

@MainActor
final class UpdateControllerTests: XCTestCase {
    private let fixture = Data("""
    {
      "tag_name": "v1.1",
      "assets": [
        {"name": "Sift-1.1.dmg", "browser_download_url": "https://github.com/YaoKaiLun/Sift/releases/download/v1.1/Sift-1.1.dmg"}
      ]
    }
    """.utf8)

    func testCheckHigherReleaseBecomesAvailable() async throws {
        let controller = UpdateController(
            current: Version("1.0")!,
            fetching: FixtureReleaseFetcher(data: fixture))
        await controller.check(automatic: false)
        guard case .available(let update) = controller.state else {
            return XCTFail("应为 available，实际是 \(controller.state)")
        }
        XCTAssertEqual(update.version, Version("1.1"))
    }

    func testManualCheckWhenCurrentIsLatestShowsMessage() async throws {
        let controller = UpdateController(
            current: Version("1.1")!,
            fetching: FixtureReleaseFetcher(data: fixture))
        await controller.check(automatic: false)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.userMessage, L10n.upToDate("1.1"))
    }

    func testManualCheckNetworkFailureUsesLocalizedMessage() async {
        let controller = UpdateController(
            current: Version("1.1")!,
            fetching: FailingReleaseFetcher(error: URLError(.badServerResponse)))
        await controller.check(automatic: false)
        XCTAssertEqual(controller.userMessage, L10n.cannotCheckUpdates)
        XCTAssertFalse(controller.userMessage?.contains("NSURLErrorDomain") ?? true)
        XCTAssertFalse(controller.userMessage?.contains("-1011") ?? true)
    }
}

private struct FailingReleaseFetcher: ReleaseFetching {
    let error: Error
    func latestReleaseData() async throws -> Data { throw error }
}

