import XCTest
@testable import DiffEngine

final class FileFilterTests: XCTestCase {
    func testImageSuffix() {
        XCTAssertTrue(FileFilter.matches(path: "docs/shot.PNG", patterns: ["*.png"]))
        XCTAssertFalse(FileFilter.matches(path: "src/App.ts", patterns: ["*.png"]))
    }

    func testTestFileGlobs() {
        XCTAssertTrue(FileFilter.matches(path: "FooTest.swift", patterns: ["*Test.swift"]))
        XCTAssertTrue(FileFilter.matches(path: "a.spec.ts", patterns: ["*.spec.ts"]))
        XCTAssertFalse(FileFilter.matches(path: "Foo.swift", patterns: ["*Test.swift"]))
    }

    func testDirectorySegment() {
        XCTAssertTrue(FileFilter.matches(path: "src/fixtures/a.json", patterns: ["fixtures/"]))
        XCTAssertFalse(FileFilter.matches(path: "src/fixture-data/a.json", patterns: ["fixtures/"]))
    }

    func testHidingDisabledKeepsAll() {
        let paths = ["a.png", "b.ts"]
        XCTAssertEqual(
            FileFilter.hiding(paths, path: { $0 }, enabled: false, patterns: ["*.png"]),
            paths)
    }

    func testHidingDropsMatches() {
        XCTAssertEqual(
            FileFilter.hiding(["a.png", "b.ts"], path: { $0 },
                              enabled: true, patterns: ["*.png"]),
            ["b.ts"])
    }
}
