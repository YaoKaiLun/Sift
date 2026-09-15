import XCTest
@testable import UpdateKit

final class VersionTests: XCTestCase {
    func testParsesVPrefixAndComparesByNumericSegments() {
        XCTAssertEqual(Version("v1.2.3"), Version("1.2.3"))
        XCTAssertEqual(Version("1.0"), Version("1.0.0"))
        XCTAssertTrue(Version("1.0")! < Version("1.0.1")!)
        XCTAssertTrue(Version("1.0.1")! < Version("1.2")!)
        XCTAssertTrue(Version("1.2")! < Version("1.10")!)
        XCTAssertFalse(Version("1.10")! < Version("1.2")!)
    }

    func testRejectsNonNumericSegments() {
        XCTAssertNil(Version("1.a"))
        XCTAssertNil(Version(""))
    }
}
