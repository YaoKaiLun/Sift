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
        XCTAssertEqual(L10n.pinRepository, "置顶仓库")
        XCTAssertEqual(L10n.discardWorktreeChanges(count: 1), "放弃修改")
        XCTAssertEqual(L10n.showInFinder, "在 Finder 中显示")
        XCTAssertEqual(L10n.copyCodeReference, "复制代码引用")
        XCTAssertEqual(L10n.copied, "已复制")
        XCTAssertEqual(L10n.findEllipsis, "查找…")
        XCTAssertEqual(L10n.upToDate("1.1"), "已是最新版本（1.1）。")
        XCTAssertEqual(L10n.cannotCheckUpdates, "无法检查更新，请稍后重试。")
    }

    func testEnglishOverride() {
        L10n.languageOverride = .english
        XCTAssertEqual(L10n.repositories, "Repositories")
        XCTAssertEqual(L10n.pinRepository, "Pin Repository")
        XCTAssertEqual(L10n.discardWorktreeChanges(count: 2), "Discard Changes in 2 Files")
        XCTAssertEqual(L10n.showInFinder, "Show in Finder")
        XCTAssertEqual(L10n.copyCodeReference, "Copy Code Reference")
        XCTAssertEqual(L10n.copied, "Copied")
        XCTAssertEqual(L10n.findEllipsis, "Find…")
        XCTAssertEqual(L10n.upToDate("1.1"), "You're on the latest version (1.1).")
        XCTAssertEqual(L10n.cannotCheckUpdates, "Couldn't check for updates. Try again later.")
    }
}
