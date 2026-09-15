import AppKit
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

    func testLeadingPassthroughCoversOverlayOverlap() {
        XCTAssertTrue(SplitOverlayLayout.shouldPassthroughLeadingHit(0, hitWidth: 11))
        XCTAssertTrue(SplitOverlayLayout.shouldPassthroughLeadingHit(5.4, hitWidth: 11))
        XCTAssertFalse(SplitOverlayLayout.shouldPassthroughLeadingHit(5.5, hitWidth: 11))
        XCTAssertFalse(SplitOverlayLayout.shouldPassthroughLeadingHit(20, hitWidth: 11))
    }

    func testDividerAtXUsesCenteredHitZones() {
        XCTAssertEqual(
            SplitOverlayLayout.divider(atX: 220, showsSidebar: true,
                                       sidebarWidth: 220, fileListWidth: 300),
            .sidebar)
        XCTAssertEqual(
            SplitOverlayLayout.divider(atX: 520, showsSidebar: true,
                                       sidebarWidth: 220, fileListWidth: 300),
            .fileList)
        XCTAssertNil(
            SplitOverlayLayout.divider(atX: 400, showsSidebar: true,
                                       sidebarWidth: 220, fileListWidth: 300))
    }

    @MainActor
    func testDiffHostViewPassesLeadingHitsThrough() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let host = DiffHostView(frame: parent.bounds)
        let child = NSView(frame: host.bounds)
        parent.addSubview(host)
        host.addSubview(child)

        XCTAssertNil(host.hitTest(NSPoint(x: 3, y: 100)))
        XCTAssertTrue(host.hitTest(NSPoint(x: 20, y: 100)) === child)
    }
}
