import XCTest
@testable import SiftUI

final class SplitOverlayLayoutTests: XCTestCase {
    func testHitMinXsCentersOnBoundaries() {
        let hits = SplitOverlayLayout.hitMinXs(
            showsSidebar: true, sidebarWidth: 220, fileListWidth: 300, hitWidth: 11)
        XCTAssertEqual(hits.sidebar, 220 - 5.5)
        XCTAssertEqual(hits.fileList, 220 + 300 - 5.5)
    }

    func testHiddenSidebarOmitsFirstDivider() {
        let hits = SplitOverlayLayout.hitMinXs(
            showsSidebar: false, sidebarWidth: 220, fileListWidth: 300, hitWidth: 11)
        XCTAssertNil(hits.sidebar)
        XCTAssertEqual(hits.fileList, 300 - 5.5)
    }
}
