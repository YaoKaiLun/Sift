import XCTest
@testable import SiftUI

final class RepositoryDropPlacementTests: XCTestCase {
    func testUpperHalfOfGroupInsertsBefore() {
        XCTAssertFalse(RepositoryDropPlacement.insertAfter(locationY: 20, groupHeight: 80))
    }

    func testLowerHalfOfGroupInsertsAfter() {
        XCTAssertTrue(RepositoryDropPlacement.insertAfter(locationY: 50, groupHeight: 80))
    }

    func testZeroHeightGroupDoesNotInsertAfter() {
        XCTAssertFalse(RepositoryDropPlacement.insertAfter(locationY: 0, groupHeight: 0))
    }

    func testDragItemRoundTripsPathThroughJSON() throws {
        let item = RepositoryDragItem(path: "/private/tmp/repo")
        let data = try JSONEncoder().encode(item)
        XCTAssertEqual(try JSONDecoder().decode(RepositoryDragItem.self, from: data), item)
    }
}
