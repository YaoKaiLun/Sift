import XCTest
@testable import GitKit

final class NameStatusParserTests: XCTestCase {
    func testParsesOrdinaryAndRenameRecords() throws {
        var data = Data()
        data.append(contentsOf: "M".utf8); data.append(0)
        data.append(contentsOf: "a.txt".utf8); data.append(0)
        data.append(contentsOf: "A".utf8); data.append(0)
        data.append(contentsOf: "b.txt".utf8); data.append(0)
        data.append(contentsOf: "D".utf8); data.append(0)
        data.append(contentsOf: "c.txt".utf8); data.append(0)
        data.append(contentsOf: "R100".utf8); data.append(0)
        data.append(contentsOf: "old.txt".utf8); data.append(0)
        data.append(contentsOf: "new.txt".utf8); data.append(0)

        let files = try NameStatusParser.parse(data)
        XCTAssertEqual(files.map(\.path), ["a.txt", "b.txt", "c.txt", "new.txt"])
        XCTAssertEqual(files.map(\.indexStatus), [.modified, .added, .deleted, .renamed])
        XCTAssertEqual(files[3].originalPath, "old.txt")
        XCTAssertTrue(files.allSatisfy { $0.worktreeStatus == .unmodified })
    }

    func testSkipsUnknownStatusLetters() throws {
        var data = Data()
        data.append(contentsOf: "X".utf8); data.append(0)
        data.append(contentsOf: "weird.txt".utf8); data.append(0)
        data.append(contentsOf: "M".utf8); data.append(0)
        data.append(contentsOf: "ok.txt".utf8); data.append(0)
        let files = try NameStatusParser.parse(data)
        XCTAssertEqual(files.map(\.path), ["ok.txt"])
    }
}
