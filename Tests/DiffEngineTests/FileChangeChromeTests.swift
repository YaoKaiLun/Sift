import XCTest
import AppKit
import GitKit
@testable import SiftUI

final class FileChangeChromeTests: XCTestCase {
    func testUntrackedChipFillIsPurple() {
        XCTAssertEqual(FileChangeChrome.nsFill(for: .untracked), .systemPurple)
    }

    func testChipFillMatchesStatusTable() {
        XCTAssertEqual(FileChangeChrome.nsFill(for: .modified), .controlAccentColor)
        XCTAssertEqual(FileChangeChrome.nsFill(for: .added), .systemGreen)
        XCTAssertEqual(FileChangeChrome.nsFill(for: .deleted), .systemRed)
        XCTAssertEqual(FileChangeChrome.nsFill(for: .renamed), .systemPurple)
        XCTAssertEqual(FileChangeChrome.nsFill(for: .copied), .systemPurple)
        XCTAssertEqual(FileChangeChrome.nsFill(for: .unmerged), .systemOrange)
        XCTAssertEqual(FileChangeChrome.nsFill(for: .typeChanged), .controlAccentColor)
        XCTAssertEqual(FileChangeChrome.nsFill(for: .unmodified), .clear)
    }

    func testChipFitsFixedStatusColumn() {
        XCTAssertEqual(Theme.statusChipSize, CGSize(width: 18, height: 16))
        XCTAssertEqual(Theme.statusChipCornerRadius, 4)
        XCTAssertEqual(Theme.statusColumnWidth, 20)
        XCTAssertLessThanOrEqual(Theme.statusChipSize.width, Theme.statusColumnWidth)
    }
}
