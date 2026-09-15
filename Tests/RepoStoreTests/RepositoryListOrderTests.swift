import XCTest
@testable import RepoStore

final class RepositoryListOrderTests: XCTestCase {
    private func item(_ id: String, pinned: Bool = false) -> RepositoryListItem {
        RepositoryListItem(id: id, isPinned: pinned)
    }

    private func ids(_ items: [RepositoryListItem]) -> [String] {
        items.map(\.id)
    }

    func testCanonicalPathTreatsSymlinkAsSameDirectory() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-canon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)
        XCTAssertEqual(RepositoryListOrder.canonicalPath(for: link),
                       RepositoryListOrder.canonicalPath(for: real))
    }

    func testInsertNewGoesAfterPinnedThenBeforeOtherUnpinned() {
        let existing = [
            item("pin-a", pinned: true),
            item("pin-b", pinned: true),
            item("old", pinned: false),
        ]
        let result = RepositoryListOrder.insertNew(id: "new", into: existing)
        XCTAssertEqual(ids(result), ["pin-a", "pin-b", "new", "old"])
        XCTAssertFalse(try XCTUnwrap(result.first { $0.id == "new" }).isPinned)
    }

    func testInsertNewIntoEmptyList() {
        let result = RepositoryListOrder.insertNew(id: "only", into: [])
        XCTAssertEqual(ids(result), ["only"])
        XCTAssertFalse(result[0].isPinned)
    }

    func testPinMovesToEndOfPinnedGroup() {
        let existing = [
            item("pin", pinned: true),
            item("a"),
            item("b"),
        ]
        let result = RepositoryListOrder.setPinned(true, id: "b", in: existing)
        XCTAssertEqual(ids(result), ["pin", "b", "a"])
        XCTAssertEqual(result.map(\.isPinned), [true, true, false])
    }

    func testUnpinMovesToStartOfUnpinnedGroup() {
        let existing = [
            item("pin-a", pinned: true),
            item("pin-b", pinned: true),
            item("old"),
        ]
        let result = RepositoryListOrder.setPinned(false, id: "pin-a", in: existing)
        XCTAssertEqual(ids(result), ["pin-b", "pin-a", "old"])
        XCTAssertEqual(result.map(\.isPinned), [true, false, false])
    }

    func testSetPinnedIsNoOpWhenAlreadyInDesiredState() {
        let existing = [item("pin", pinned: true), item("a")]
        XCTAssertEqual(RepositoryListOrder.setPinned(true, id: "pin", in: existing), existing)
        XCTAssertEqual(RepositoryListOrder.setPinned(false, id: "a", in: existing), existing)
    }

    func testMoveOntoPinnedRowPinsAndReorders() {
        let existing = [
            item("pin", pinned: true),
            item("a"),
            item("b"),
        ]
        let result = RepositoryListOrder.move(id: "b", relativeTo: "pin", after: true, in: existing)
        XCTAssertEqual(ids(result), ["pin", "b", "a"])
        XCTAssertTrue(try XCTUnwrap(result.first { $0.id == "b" }).isPinned)
    }

    func testMoveOntoUnpinnedRowUnpinsAndReorders() {
        let existing = [
            item("pin-a", pinned: true),
            item("pin-b", pinned: true),
            item("a"),
        ]
        let result = RepositoryListOrder.move(id: "pin-a", relativeTo: "a", after: false, in: existing)
        XCTAssertEqual(ids(result), ["pin-b", "pin-a", "a"])
        XCTAssertFalse(try XCTUnwrap(result.first { $0.id == "pin-a" }).isPinned)
    }

    func testMoveSameRowIsNoOp() {
        let existing = [item("a"), item("b")]
        XCTAssertEqual(RepositoryListOrder.move(id: "a", relativeTo: "a", after: true, in: existing), existing)
    }

    func testIsAboveUsesCurrentListOrder() {
        let existing = [item("a"), item("b"), item("c")]
        XCTAssertTrue(RepositoryListOrder.isAbove(id: "a", relativeTo: "c", in: existing))
        XCTAssertFalse(RepositoryListOrder.isAbove(id: "c", relativeTo: "a", in: existing))
        XCTAssertFalse(RepositoryListOrder.isAbove(id: "missing", relativeTo: "a", in: existing))
    }

    func testNormalizePullsPinnedAheadPreservingRelativeOrder() {
        let mixed = [
            item("a"),
            item("pin-b", pinned: true),
            item("c"),
            item("pin-d", pinned: true),
        ]
        let result = RepositoryListOrder.normalize(mixed)
        XCTAssertEqual(ids(result), ["pin-b", "pin-d", "a", "c"])
        XCTAssertEqual(result.map(\.isPinned), [true, true, false, false])
    }
}
