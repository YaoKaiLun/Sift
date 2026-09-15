import XCTest
@testable import UpdateKit

final class UpdateInstallerTests: XCTestCase {
    func testRestartScriptContainsPidDittoAndOpen() {
        let script = UpdateInstaller.restartScript(
            pid: 42,
            stagedApp: URL(fileURLWithPath: "/tmp/Sift-next.app"),
            targetApp: URL(fileURLWithPath: "/Applications/Sift.app"))
        XCTAssertTrue(script.contains("while kill -0 42"))
        XCTAssertTrue(script.contains("ditto"))
        XCTAssertTrue(script.contains("xattr -cr"))
        XCTAssertTrue(script.contains("open"))
        XCTAssertTrue(script.contains("/tmp/Sift-next.app"))
        XCTAssertTrue(script.contains("/Applications/Sift.app"))
    }
}
