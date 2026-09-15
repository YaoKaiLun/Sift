import XCTest
import SiftLocalization

final class L10nTests: XCTestCase {
    override func tearDown() {
        L10n.languageOverride = nil
        super.tearDown()
    }

    func testChineseOverride() {
        L10n.languageOverride = .chinese
        XCTAssertEqual(L10n.repositories, "仓库")
        XCTAssertEqual(L10n.upToDate("1.1"), "已是最新版本（1.1）。")
    }

    func testEnglishOverride() {
        L10n.languageOverride = .english
        XCTAssertEqual(L10n.repositories, "Repositories")
        XCTAssertEqual(L10n.upToDate("1.1"), "You're on the latest version (1.1).")
    }
}
